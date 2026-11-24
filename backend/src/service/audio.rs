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
#[derive(Clone, Copy, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum MasterScope {
    #[default]
    All,
    Inputs,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MasterMute {
    generation: String,
    muted: bool,
    #[serde(default)]
    scope: MasterScope,
}
impl Service {
    pub(super) async fn profile_request(&self, request: &Request) -> Result<Value> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Set {
            identity: Identity,
            profile: String,
        }
        let params = request.params::<Set>()?;
        let native = self
            .native
            .as_ref()
            .ok_or_else(|| Failure::new("disconnected", "Native audio is unavailable"))?;
        let _transaction = self.transaction().await?;
        let _external_lock = FileLock::mutation().await?;
        self.set_busy_for(true, "profile.set");
        let _busy = Busy(self);
        let result = crate::profiles::select(
            native,
            self.storage.as_ref(),
            params.identity,
            &params.profile,
        )
        .await;
        self.reload_stores().await?;
        result
    }

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

    pub(super) async fn master_mute_request(&self, request: &Request) -> Result<Value> {
        let params = request.params::<MasterMute>()?;
        let native = self
            .native
            .as_ref()
            .ok_or_else(|| Failure::new("disconnected", "Native audio is unavailable"))?;
        let _transaction = self.transaction().await?;
        let _external_lock = FileLock::mutation().await?;
        self.set_busy_for(true, "audio.mute_all");
        let _busy = Busy(self);
        let graph = native.snapshot();
        if !graph.ready || !graph.connected || graph.generation != params.generation {
            return Err(Failure::new(
                "stale_graph",
                "Audio graph changed; refresh before retrying",
            ));
        }
        if graph.nodes.len() > 4096 || graph.links.len() > 8192 {
            return Err(Failure::new(
                "too_large",
                "Audio graph is too large to mute safely",
            ));
        }
        let collect_targets = |graph: &native::Graph, muted: bool| -> Vec<(Identity, bool)> {
            let active = crate::outputs::master_targets(graph);
            let mut seen = std::collections::BTreeSet::new();
            let mut targets = Vec::new();
            let mut push_node = |node: &native::Node| {
                if seen.insert(node.id) && node.audio.muted.is_some_and(|current| current != muted)
                {
                    let is_stream = crate::routing::stream_direction(node).is_some();
                    targets.push((crate::routing::identity(graph, node), is_stream));
                }
            };
            match params.scope {
                MasterScope::All => {
                    for node in active.outputs.values().chain(active.inputs.values()) {
                        push_node(node);
                    }
                    if !muted {
                        for node in active.muted_recording_streams.values() {
                            push_node(node);
                        }
                    }
                }
                MasterScope::Inputs => {
                    for node in active.inputs.values() {
                        push_node(node);
                    }
                    if !muted {
                        for node in active.muted_recording_streams.values() {
                            push_node(node);
                        }
                    }
                }
            }
            if !muted {
                let remembered: Vec<(u32, String)> = {
                    let state = self.master_muted_streams.lock().unwrap();
                    if state.generation == params.generation {
                        state.streams.iter().cloned().collect()
                    } else {
                        Vec::new()
                    }
                };
                for (id, serial) in remembered {
                    if let Some(node) = graph.nodes.get(&id) {
                        if node.serial != serial {
                            continue;
                        }
                        let direction = crate::routing::stream_direction(node);
                        let in_scope = match params.scope {
                            MasterScope::All => direction.is_some(),
                            MasterScope::Inputs => {
                                direction == Some(crate::routing::Direction::Recording)
                            }
                        };
                        if in_scope {
                            push_node(node);
                        }
                    }
                }
            }
            targets
        };
        let record_stream_mute = |identity: &Identity, is_stream: bool, muted: bool| {
            if !is_stream {
                return;
            }
            let mut state = self.master_muted_streams.lock().unwrap();
            if state.generation != identity.generation {
                state.generation = identity.generation.clone();
                state.streams.clear();
            }
            if muted {
                if state.streams.len() < 256 {
                    state.streams.insert((identity.id, identity.serial.clone()));
                }
            } else {
                state
                    .streams
                    .remove(&(identity.id, identity.serial.clone()));
            }
        };
        let node_gone = |graph: &native::Graph, identity: &Identity| {
            graph.generation == params.generation
                && graph
                    .nodes
                    .get(&identity.id)
                    .is_none_or(|node| node.serial != identity.serial)
        };
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
        let targets = collect_targets(&graph, params.muted);
        let mut attempted = std::collections::BTreeSet::new();
        let mut failed: Option<Failure> = None;
        for (identity, is_stream) in targets {
            if tokio::time::Instant::now() >= deadline {
                failed = Some(Failure::unknown(
                    "Audio change was not confirmed by PipeWire",
                ));
                break;
            }
            attempted.insert((identity.id, identity.serial.clone()));
            match tokio::time::timeout_at(
                deadline,
                native.patch(
                    identity.clone(),
                    AudioPatch {
                        muted: Some(params.muted),
                        volumes: None,
                    },
                ),
            )
            .await
            {
                Ok(Ok(())) => {
                    record_stream_mute(&identity, is_stream, params.muted);
                }
                Ok(Err(error)) => {
                    if node_gone(&native.snapshot(), &identity) {
                        record_stream_mute(&identity, is_stream, false);
                        continue;
                    }
                    if failed.is_none() || error.outcome == "unknown" {
                        failed = Some(error);
                    }
                }
                Err(_) => {
                    failed = Some(Failure::unknown(
                        "Audio change was not confirmed by PipeWire",
                    ));
                    break;
                }
            }
        }
        // If a new active destination appeared while muting, cover it before confirming.
        if params.muted && tokio::time::Instant::now() < deadline {
            let current = native.snapshot();
            if current.ready && current.connected && current.generation == params.generation {
                let remaining: Vec<(Identity, bool)> = collect_targets(&current, true)
                    .into_iter()
                    .filter(|(identity, _)| {
                        !attempted.contains(&(identity.id, identity.serial.clone()))
                    })
                    .collect();
                for (identity, is_stream) in remaining {
                    if tokio::time::Instant::now() >= deadline {
                        failed = Some(Failure::unknown(
                            "Audio change was not confirmed by PipeWire",
                        ));
                        break;
                    }
                    match tokio::time::timeout_at(
                        deadline,
                        native.patch(
                            identity.clone(),
                            AudioPatch {
                                muted: Some(true),
                                volumes: None,
                            },
                        ),
                    )
                    .await
                    {
                        Ok(Ok(())) => {
                            record_stream_mute(&identity, is_stream, true);
                        }
                        Ok(Err(error)) => {
                            if node_gone(&native.snapshot(), &identity) {
                                continue;
                            }
                            if failed.is_none() || error.outcome == "unknown" {
                                failed = Some(error);
                            }
                        }
                        Err(_) => {
                            failed = Some(Failure::unknown(
                                "Audio change was not confirmed by PipeWire",
                            ));
                            break;
                        }
                    }
                }
            }
        }
        if !params.muted {
            // Prune entries whose nodes disappeared or are no longer muted.
            let current = native.snapshot();
            let mut state = self.master_muted_streams.lock().unwrap();
            if state.generation != current.generation {
                state.generation = current.generation.clone();
                state.streams.clear();
            } else {
                state.streams.retain(|(id, serial)| {
                    current.nodes.get(id).is_some_and(|node| {
                        node.serial == *serial && node.audio.muted == Some(true)
                    })
                });
            }
        }
        self.publish_graph(&native.snapshot());
        if let Some(error) = failed {
            return Err(error);
        }
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
        let _lock = FileLock::mutation().await?;
        self.set_busy(true);
        let _busy = Busy(self);
        let _ = self.reload_stores().await;
        let snapshot = self.state.borrow().clone();
        let overdrive = snapshot["stores"]["settings"]["outputOverdrive"] == true;
        let rules = snapshot["stores"]["rules"]
            .is_object()
            .then_some(&snapshot["stores"]["rules"]);
        let mut group_reconcile = None;
        let result = if request.method == "scene.apply" {
            crate::scenes::apply(
                native,
                self.storage.as_ref(),
                rules,
                &request.params::<Apply>()?.scene,
                overdrive,
                &mut group_reconcile,
            )
            .await
        } else {
            crate::scenes::capture(native, rules, &request.params::<Capture>()?.name, overdrive)
        };
        if let Some(reconciled) = group_reconcile {
            self.apply_reconcile_state(reconciled);
        }
        self.reload_stores().await?;
        result
    }
}
