//! Device-level commands and whole-scene transaction boundaries.
use super::{Busy, Service};
use crate::files::FileLock;
use crate::native::{self, AudioPatch, Identity};
use crate::protocol::{Failure, Request, Result};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NodeAudio {
    identity: Identity,
    patch: AudioPatch,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NodeLevel {
    identity: Identity,
    volume: Option<f64>,
    balance: Option<f64>,
    muted: Option<bool>,
}
impl Service {
    pub(super) async fn port_request(&self, request: &Request) -> Result<Value> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Set {
            identity: Identity,
            port: String,
        }
        let params = request.params::<Set>()?;
        let native = self
            .native
            .as_ref()
            .ok_or_else(|| Failure::new("disconnected", "Native audio is unavailable"))?;
        let _transaction = self.transaction().await?;
        let _external_lock = FileLock::mutation().await?;
        self.set_busy_for(true, "port.set");
        let _busy = Busy(self);
        native.select_port(params.identity, &params.port).await?;
        Ok(json!({"outcome":"applied"}))
    }

    pub(super) async fn audio_request(&self, request: &Request) -> Result<Value> {
        let native = self
            .native
            .as_ref()
            .ok_or_else(|| Failure::new("disconnected", "Native audio is unavailable"))?;
        let _transaction = self.transaction().await?;
        self.set_busy_for(true, "node.audio");
        let _busy = Busy(self);
        let graph = native.snapshot();
        let params = if request.method == "node.audio" {
            request.params::<NodeAudio>()?
        } else {
            let level = request.params::<NodeLevel>()?;
            let node = native::validate_identity(&graph, &level.identity)?;
            let mut volumes = node.audio.volumes.clone();
            if let Some(volume) = level.volume {
                if !volume.is_finite() || !(0.0..=1.5).contains(&volume) {
                    return Err(Failure::new("invalid_params", "Invalid volume"));
                }
                let peak = volumes.iter().copied().fold(0.0, f64::max);
                for value in &mut volumes {
                    *value = if peak > 0.0 {
                        *value / peak * volume
                    } else {
                        volume
                    };
                }
            }
            if let Some(balance) = level.balance {
                if !balance.is_finite() || !(-1.0..=1.0).contains(&balance) {
                    return Err(Failure::new("invalid_params", "Invalid balance"));
                }
                let pair = node
                    .audio
                    .channels
                    .iter()
                    .position(|c| *c == 3)
                    .zip(node.audio.channels.iter().position(|c| *c == 4))
                    .or({
                        if volumes.len() == 2 {
                            Some((0, 1))
                        } else {
                            None
                        }
                    });
                let (left, right) = pair
                    .filter(|(l, r)| *l < volumes.len() && *r < volumes.len())
                    .ok_or_else(|| Failure::new("unsupported", "Node has no stereo channels"))?;
                let peak = volumes[left].max(volumes[right]);
                volumes[left] = peak * if balance > 0.0 { 1.0 - balance } else { 1.0 };
                volumes[right] = peak * if balance < 0.0 { 1.0 + balance } else { 1.0 };
            }
            NodeAudio {
                identity: level.identity,
                patch: AudioPatch {
                    muted: level.muted,
                    volumes: if level.volume.is_some() || level.balance.is_some() {
                        Some(volumes)
                    } else {
                        None
                    },
                },
            }
        };
        let node = native::validate_identity(&graph, &params.identity)?;
        if !node
            .properties
            .get("media.class")
            .is_some_and(|class| class.starts_with("Audio/") || class.starts_with("Stream/"))
        {
            return Err(Failure::new(
                "invalid_target",
                "Node is not an audio endpoint or stream",
            ));
        }
        let ceiling = if node
            .properties
            .get("media.class")
            .is_some_and(|class| matches!(class.as_str(), "Audio/Sink" | "Stream/Output/Audio"))
            && self.state.borrow()["stores"]["settings"]["outputOverdrive"] != true
        {
            1.0
        } else {
            1.5
        };
        if params
            .patch
            .volumes
            .as_ref()
            .is_some_and(|levels| levels.iter().any(|v| *v > ceiling))
        {
            return Err(Failure::new(
                "volume_limit",
                "Requested volume exceeds the configured limit",
            ));
        }
        let _external_lock = FileLock::mutation().await?;
        native.patch(params.identity, params.patch).await?;
        Ok(json!({"outcome": "applied"}))
    }

    pub(super) async fn scene_request(&self, request: &Request) -> Result<Value> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Apply {
            scene: Value,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Capture {
            name: String,
        }
        let native = self
            .native
            .as_ref()
            .ok_or_else(|| Failure::new("disconnected", "Native audio is unavailable"))?;
        let _transaction = self.transaction().await?;
        let lock = FileLock::mutation().await?;
        self.set_busy(true);
        let _busy = Busy(self);
        let overdrive = self.state.borrow()["stores"]["settings"]["outputOverdrive"] == true;
        let result = if request.method == "scene.apply" {
            crate::scenes::apply(
                native,
                &self.adapter,
                &lock,
                &request.params::<Apply>()?.scene,
                overdrive,
            )
            .await
        } else {
            crate::scenes::capture(native, &request.params::<Capture>()?.name, overdrive)
        };
        self.reload_stores().await?;
        result
    }
}
