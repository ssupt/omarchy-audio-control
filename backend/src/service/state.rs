//! Snapshot publication and persisted-store observation.
use super::{Busy, Service};
use crate::native;
use crate::protocol::{Failure, Request, Result};
use crate::storage::{self, Kind};
use serde_json::{Value, json};
use std::sync::Arc;

impl Service {
    pub(super) fn update_state(&self, change: impl FnOnce(&mut Value)) {
        self.state.send_modify(|state| {
            let value = Arc::make_mut(state);
            // Assign under the same lock as publication so concurrent graph/file
            // updates cannot publish a decreasing revision.
            let revision = value["revision"]
                .as_str()
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0)
                + 1;
            change(value);
            value["revision"] = json!(revision.to_string());
        });
    }

    pub(super) fn publish_graph(&self, graph: &native::Graph) {
        let nodes: Vec<_> = graph
            .nodes
            .values()
            .map(|node| json!([node.id, node.serial, node.properties]))
            .collect();
        let fingerprint = json!([
            graph.generation,
            graph.ready,
            nodes,
            graph.devices,
            graph.metadata
        ])
        .to_string();
        let mut catalog = self.catalog.lock().unwrap();
        self.update_state(|state| {
            if *catalog != fingerprint {
                *catalog = fingerprint;
                let revision = state["catalogRevision"]
                    .as_str()
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(0)
                    + 1;
                state["catalogRevision"] = json!(revision.to_string());
                let (profiles, ports) = native::catalog::snapshot(graph);
                state["profiles"] = profiles;
                state["ports"] = ports;
            }
            state["connected"] = json!(graph.connected);
            state["graphReady"] = json!(graph.ready);
            state["catalogReady"] = json!(native::catalog::ready(graph));
            state["generation"] = json!(graph.generation);
            state["error"] = json!(graph.error);
            state["nodes"] = json!(graph.nodes.values().collect::<Vec<_>>());
            state["devices"] = json!(graph.devices.values().collect::<Vec<_>>());
            state["links"] = json!(graph.links.values().collect::<Vec<_>>());
            state["metadata"] = json!(graph.metadata);
            state["policies"] = super::policy::snapshot(graph);
        });
    }

    pub(super) async fn reload_stores(&self) -> Result<()> {
        let Some(storage) = self.storage.clone() else {
            return Ok(());
        };
        let stores =
            tokio::task::spawn_blocking(move || Kind::ALL.map(|kind| (kind, storage.read(kind))))
                .await
                .map_err(|_| Failure::new("internal_error", "Store reader stopped"))?;
        self.update_state(|state| {
            if !state["stores"].is_object() {
                state["stores"] = json!({});
            }
            if !state["storeErrors"].is_object() {
                state["storeErrors"] = json!({});
            }
            for (kind, result) in stores {
                match result {
                    Ok(value) => {
                        state["stores"][kind.key()] = value;
                        state["storeErrors"]
                            .as_object_mut()
                            .unwrap()
                            .shift_remove(kind.key());
                    }
                    Err(error) => {
                        if state["stores"].get(kind.key()).is_none() {
                            state["stores"][kind.key()] = storage::normalize(kind, &json!({}));
                        }
                        state["storeErrors"][kind.key()] = json!(error);
                    }
                }
            }
        });
        Ok(())
    }

    pub(super) fn watch_stores(self: &Arc<Self>) {
        let Some(storage) = self.storage.clone() else {
            return;
        };
        let weak = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                let paths = Kind::ALL
                    .into_iter()
                    .map(|kind| storage.path(kind))
                    .collect::<Result<Vec<_>>>();
                let watcher = paths
                    .and_then(|paths| crate::file_watch::Watcher::new(&paths).map_err(Into::into));
                if let Some(service) = weak.upgrade() {
                    // Watches precede the read so replacement during startup is observed.
                    let _guard = service.mutation.lock().await;
                    let _ = service.reload_stores().await;
                    if let Err(error) = &watcher {
                        service.update_state(|state| state["storeWatchError"] = json!(error));
                    } else {
                        service.update_state(|state| state["storeWatchError"] = Value::Null);
                    }
                } else {
                    return;
                }
                if let Ok(watcher) = watcher {
                    while watcher.changed().await.is_ok() {
                        tokio::time::sleep(std::time::Duration::from_millis(40)).await;
                        let Some(service) = weak.upgrade() else {
                            return;
                        };
                        let _guard = service.mutation.lock().await;
                        let _ = service.reload_stores().await;
                    }
                }
                if weak.strong_count() == 0 {
                    return;
                }
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        });
    }

    pub(super) async fn store_request(&self, request: &Request) -> Result<Value> {
        let storage = self
            .storage
            .clone()
            .ok_or_else(|| Failure::new("unavailable", "Stores are unavailable"))?;
        let _transaction = self.transaction().await?;
        self.set_busy(true);
        let _busy = Busy(self);
        let request = request.clone();
        let result = tokio::task::spawn_blocking(move || storage.handle(&request))
            .await
            .map_err(|_| Failure::unknown("Store operation stopped unexpectedly"))?;
        self.reload_stores().await?;
        result?.ok_or_else(|| Failure::new("method_not_found", "Unknown store method"))
    }
}
