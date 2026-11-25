//! Snapshot publication and persisted-store observation.
use super::{Busy, Service};
use crate::native;
use crate::protocol::{self, Failure, MAX_FRAME_BYTES, Request, Response, Result};
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
            .map(|node| {
                json!([
                    node.id,
                    node.serial,
                    node.properties,
                    !node.state.is_empty()
                ])
            })
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
        if graph.sequence != 0 && graph.sequence <= catalog.last_sequence {
            return;
        }
        if graph.sequence != 0 {
            catalog.last_sequence = graph.sequence;
        }
        let links = json!(graph.links.values().collect::<Vec<_>>());
        self.update_state(|state| {
            if catalog.fingerprint != fingerprint || state["links"] != links {
                state["routes"] = crate::routing::snapshot(graph);
                state["outputs"] = crate::outputs::snapshot(graph);
            }
            if catalog.fingerprint != fingerprint {
                catalog.fingerprint = fingerprint;
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
            state["master"] = crate::outputs::master_snapshot(graph);
            state["nodes"] = json!(graph.nodes.values().collect::<Vec<_>>());
            state["devices"] = json!(graph.devices.values().collect::<Vec<_>>());
            state["links"] = links;
            state["metadata"] = json!(graph.metadata);
            state["policies"] = super::policy::snapshot(graph);
        });
    }

    pub(super) async fn reload_stores(&self) -> Result<()> {
        let Some(storage) = self.storage.clone() else {
            return Ok(());
        };
        let _store_sync = self.store_sync.lock().await;
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
        let forgetting = request.method == "devices.forget";
        let _transaction = self.transaction().await?;
        let _external = if forgetting {
            Some(crate::files::FileLock::mutation().await?)
        } else {
            None
        };
        self.set_busy(true);
        let _busy = Busy(self);
        let command = request.clone();
        let result = tokio::task::spawn_blocking(move || storage.handle(&command))
            .await
            .map_err(|_| Failure::unknown("Store operation stopped unexpectedly"))?;
        self.reload_stores().await?;
        if forgetting && result.is_ok() {
            if let Some(native) = &self.native {
                let storage = self.storage.clone().unwrap();
                let native = native.clone();
                // The saved group is gone even when its old combine module is
                // still briefly in use; reconciliation removes it once safe.
                if let Ok(reconciled) = tokio::task::spawn_blocking(move || {
                    crate::groups::apply(&native, &storage, crate::groups::Change::Reconcile)
                })
                .await
                {
                    self.apply_reconcile_state(reconciled);
                }
            }
        }
        let value =
            result?.ok_or_else(|| Failure::new("method_not_found", "Unknown store method"))?;
        // Stores can exceed a single response frame. Subscribers receive the
        // updated document through bounded snapshot chunks before completion.
        if request.method != "store.read" {
            return Ok(json!({"outcome": "applied"}));
        }
        let response = Response::new(Some(&request.id), Ok(value.clone()));
        if protocol::encode(&response)?.len() + 1 > MAX_FRAME_BYTES {
            return Err(Failure::new(
                "response_too_large",
                "Audio store is too large for one reply; use state.subscribe",
            ));
        }
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::super::Service;
    use crate::native::Graph;

    #[test]
    fn publish_graph_ignores_older_sequence_snapshots() {
        let service = Service::new().unwrap();
        let newer = Graph {
            sequence: 5,
            connected: true,
            ready: true,
            generation: "gen-1".into(),
            ..Graph::default()
        };
        let older = Graph {
            sequence: 4,
            connected: false,
            ready: false,
            generation: "gen-0".into(),
            ..Graph::default()
        };
        service.publish_graph(&newer);
        service.publish_graph(&older);
        let state = service.state.borrow().clone();
        assert_eq!(state["connected"], true);
        assert_eq!(state["generation"], "gen-1");
    }
}
