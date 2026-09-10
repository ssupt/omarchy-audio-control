//! WirePlumber settings share the graph subscription and transaction queue.
use super::{Busy, Service};
use crate::files::FileLock;
use crate::native::{
    Graph, MetadataValue,
    metadata::{self, Batch, Change},
};
use crate::protocol::{Failure, Request, Result};
use serde::Deserialize;
use serde_json::{Value, json};

const SETTINGS: &[&str] = &[
    "node.features.audio.mono",
    "linking.pause-playback",
    "device.routes.mute-on-alsa-playback-removed",
    "device.routes.mute-on-bluetooth-playback-removed",
    "monitor.alsa.autodetect-hdmi-channels",
    "device.routes.default-sink-volume",
    "device.routes.default-source-volume",
    "node.stream.default-playback-volume",
    "node.stream.default-capture-volume",
    "bluetooth.autoswitch-to-headset-profile",
    "bluetooth.profile-preference",
];

fn valid(key: &str, value: &Value) -> bool {
    if !SETTINGS.contains(&key) {
        return false;
    }
    if key.ends_with("-volume") {
        value.as_f64().is_some_and(|v| (0.0..=1.0).contains(&v))
    } else if key == "bluetooth.profile-preference" {
        matches!(value.as_str(), Some("quality" | "latency"))
    } else {
        value.is_boolean()
    }
}

fn current(graph: &Graph, key: &str) -> Option<Value> {
    metadata::value(graph, "schema-sm-settings", key)?;
    let raw = &metadata::value(graph, "sm-settings", key)?.value;
    // SPA JSON also accepts bare strings, as emitted by wpctl settings.
    let value = serde_json::from_str(raw).unwrap_or_else(|_| json!(raw.trim()));
    valid(key, &value).then_some(value)
}

pub(super) fn snapshot(graph: &Graph) -> Value {
    let mut values = serde_json::Map::new();
    if graph.ready && graph.connected && graph.metadata_ids.contains_key("persistent-sm-settings") {
        for key in SETTINGS {
            if let Some(mut value) = current(graph, key) {
                if key.ends_with("-volume") {
                    value = json!(value.as_f64().unwrap().cbrt());
                }
                values.insert((*key).into(), value);
            }
        }
    }
    Value::Object(values)
}

impl Service {
    pub(super) async fn policy_request(&self, request: &Request) -> Result<Value> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Set {
            generation: String,
            key: String,
            value: Value,
        }
        let params = request.params::<Set>()?;
        if !valid(&params.key, &params.value) {
            return Err(Failure::new(
                "invalid_params",
                "Invalid audio policy or value",
            ));
        }
        let native = self
            .native
            .as_ref()
            .ok_or_else(|| Failure::new("disconnected", "Native audio is unavailable"))?;
        let _transaction = self.transaction().await?;
        let _lock = FileLock::mutation().await?;
        let _settings_lock = FileLock::settings().await?;
        let graph = native.snapshot();
        if !graph.ready || graph.generation != params.generation {
            return Err(Failure::new(
                "stale_graph",
                "Audio graph changed before the setting change",
            ));
        }
        current(&graph, &params.key)
            .ok_or_else(|| Failure::new("unsupported", "This audio policy is unavailable"))?;
        let value = if params.key.ends_with("-volume") {
            json!(params.value.as_f64().unwrap().powi(3))
        } else {
            params.value
        };
        let after = MetadataValue {
            subject: 0,
            key: params.key.clone(),
            type_: "Spa:String:JSON".into(),
            value: value.to_string(),
        };
        let changes = ["sm-settings", "persistent-sm-settings"]
            .into_iter()
            .map(|store| {
                let id = graph.metadata_ids.get(store).copied().ok_or_else(|| {
                    Failure::new("unsupported", "Saved audio settings are unavailable")
                })?;
                Ok(Change {
                    store,
                    id,
                    key: params.key.clone(),
                    before: metadata::value(&graph, store, &params.key).cloned(),
                    after: Some(after.clone()),
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let batch = Batch {
            generation: params.generation,
            changes,
        };
        if batch.confirmed(&graph) {
            return Ok(json!({"outcome":"applied"}));
        }
        self.set_busy(true);
        let _busy = Busy(self);
        if let Err(error) = native.metadata(batch.clone()).await {
            if error.outcome != "unknown" {
                return Err(error);
            }
            let rollback = batch.rollback(&native.snapshot()).map_err(|_| {
                Failure::unknown(
                    "Audio settings changed during the operation; rollback was skipped",
                )
            })?;
            native.metadata(rollback).await.map_err(|_| {
                Failure::unknown("Audio setting could not be confirmed or restored")
            })?;
            return Err(Failure::new(
                "not_applied",
                "Audio setting was not applied; its previous value was restored",
            ));
        }
        Ok(json!({"outcome":"applied"}))
    }
}
