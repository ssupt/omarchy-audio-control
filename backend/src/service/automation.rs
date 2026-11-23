//! Subscription-owned reconciliation. Lock retries never replay uncertain changes.
use super::{Busy, Service};
use crate::files::FileLock;
use serde_json::json;
use std::sync::Arc;

impl Service {
    pub(super) fn start_automation(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        let mut users = self.users.subscribe();
        let mut state = self.subscribe();
        tokio::spawn(async move {
            let mut signature = String::new();
            let mut groups = String::new();
            let mut attempted = std::collections::BTreeSet::new();
            let mut retry = None;
            loop {
                tokio::select! {
                    result = users.changed() => if result.is_err() {return},
                    result = state.changed() => if result.is_err() {return},
                    _ = async {
                        if let Some(deadline) = retry { tokio::time::sleep_until(deadline).await; }
                        else { std::future::pending::<()>().await; }
                    } => (),
                }
                retry = None;
                if *users.borrow_and_update() == 0 {
                    signature.clear();
                    groups.clear();
                    attempted.clear();
                    continue;
                }
                let Some(service) = weak.upgrade() else {
                    return;
                };
                let Some(native) = &service.native else {
                    return;
                };
                // A profile can replace a Bluetooth sink several times. Wait
                // until the output inventory stops changing before asking
                // Pulse to enumerate it for output-group reconciliation.
                let mut output_signature = crate::automation::group_signature(
                    &native.snapshot(),
                    &state.borrow_and_update()["stores"]["rules"],
                );
                let mut quiet_until =
                    tokio::time::Instant::now() + std::time::Duration::from_millis(600);
                loop {
                    tokio::select! {
                        _ = tokio::time::sleep_until(quiet_until) => break,
                        changed = state.changed() => {
                            if changed.is_err() { return; }
                            let next = crate::automation::group_signature(
                                &native.snapshot(),
                                &state.borrow_and_update()["stores"]["rules"],
                            );
                            if next != output_signature {
                                output_signature = next;
                                quiet_until = tokio::time::Instant::now()
                                    + std::time::Duration::from_millis(600);
                            }
                        }
                    }
                }
                let snapshot = state.borrow_and_update().clone();
                let graph = native.snapshot();
                if !graph.ready || !snapshot["stores"]["rules"].is_object() {
                    continue;
                }
                let next = crate::automation::signature(&graph, &snapshot["stores"]["rules"]);
                let next_groups =
                    crate::automation::group_signature(&graph, &snapshot["stores"]["rules"]);
                if next == signature && next_groups == groups {
                    continue;
                }
                let _transaction = service.mutation.lock().await;
                if *users.borrow() == 0 {
                    continue;
                }
                // Resolve again after the queue barrier: a scene can replace nodes.
                let graph = native.snapshot();
                let snapshot = service.state.borrow().clone();
                let rules = &snapshot["stores"]["rules"];
                if !graph.ready || *users.borrow() == 0 {
                    continue;
                }
                let next_signature = crate::automation::signature(&graph, rules);
                let next_groups = crate::automation::group_signature(&graph, rules);
                let routes = crate::automation::routes(&graph, rules);
                let keys: std::collections::BTreeSet<_> =
                    routes.iter().map(|route| route.key.clone()).collect();
                attempted.retain(|key| keys.contains(key));
                let has_group_work = rules["outputGroups"]
                    .as_array()
                    .is_some_and(|g| !g.is_empty())
                    || graph
                        .nodes
                        .values()
                        .any(|n| crate::storage::group_sink(&n.name));
                if !has_group_work {
                    service.clear_pending_groups();
                }
                let reconcile = next_groups != groups && has_group_work;
                if !reconcile && routes.iter().all(|route| attempted.contains(&route.key)) {
                    signature = next_signature;
                    groups = next_groups;
                    continue;
                }
                let _lock = match FileLock::mutation().await {
                    Ok(lock) => lock,
                    Err(error) => {
                        // An older release may still own a scene. Nothing was
                        // admitted: retry the lock, never an uncertain change.
                        if error.code == "busy" {
                            retry = Some(
                                tokio::time::Instant::now() + std::time::Duration::from_secs(1),
                            );
                        } else {
                            signature = next_signature;
                            service.update_state(|s| {
                                s["automationError"] =
                                    json!("Automatic routing could not acquire audio control")
                            });
                        }
                        continue;
                    }
                };
                if *users.borrow() == 0 {
                    continue;
                }
                // A different release/companion could have changed saved rules
                // while we waited for the cross-process lock. Read and resolve
                // again under ownership before admitting a change.
                if service.reload_stores().await.is_err() {
                    continue;
                }
                let graph = native.snapshot();
                let snapshot = service.state.borrow().clone();
                let rules = &snapshot["stores"]["rules"];
                if !graph.ready || *users.borrow() == 0 {
                    continue;
                }
                signature = crate::automation::signature(&graph, rules);
                let next_groups = crate::automation::group_signature(&graph, rules);
                let has_group_work = rules["outputGroups"]
                    .as_array()
                    .is_some_and(|g| !g.is_empty())
                    || graph
                        .nodes
                        .values()
                        .any(|n| crate::storage::group_sink(&n.name));
                if !has_group_work {
                    service.clear_pending_groups();
                }
                let reconcile = next_groups != groups && has_group_work;
                let routes = crate::automation::routes(&graph, rules);
                groups = next_groups;
                service.set_busy(true);
                let _busy = Busy(&service);
                if reconcile {
                    let result = service
                        .change_groups(crate::groups::Change::Reconcile)
                        .await;
                    service.apply_reconcile_state(result);
                }
                let started = std::time::Instant::now();
                let mut pending_tracker = PendingClearTracker::default();
                let mut route_iter = routes.into_iter();
                while let Some(route) = route_iter.next() {
                    if *users.borrow() == 0 || started.elapsed().as_secs() > 60 {
                        pending_tracker.record_incomplete(route.clear_pending);
                        for remaining in route_iter {
                            pending_tracker.record_incomplete(remaining.clear_pending);
                        }
                        break;
                    }
                    if attempted.contains(&route.key) {
                        pending_tracker.record_incomplete(route.clear_pending);
                        continue;
                    }
                    match crate::routing::set(native, &route.set).await {
                        Ok(()) => {
                            pending_tracker.record_success(route.clear_pending);
                        }
                        Err(error)
                            if error.code == "stale_node"
                                && native
                                    .snapshot()
                                    .nodes
                                    .get(&route.set.identity.id)
                                    .is_none_or(|node| {
                                        node.serial != route.set.identity.serial
                                    }) => {}
                        Err(error) => {
                            pending_tracker.record_incomplete(route.clear_pending);
                            attempted.insert(route.key);
                            service.update_state(|s| {
                                s["automationError"] =
                                    json!("An application rule could not be applied")
                            });
                            if error.outcome == "unknown" {
                                for remaining in route_iter {
                                    pending_tracker.record_incomplete(remaining.clear_pending);
                                }
                                break;
                            }
                        }
                    }
                }
                let cleared_pending = pending_tracker.finish();
                if !cleared_pending.is_empty() {
                    if let Some(storage) = service.storage.clone() {
                        let _ = tokio::task::spawn_blocking(move || {
                            storage.update(crate::storage::Kind::Rules, |store| {
                                for (app, direction) in &cleared_pending {
                                    crate::storage::set_pending_default(
                                        store, app, direction, false,
                                    );
                                }
                                Ok(())
                            })
                        })
                        .await;
                        let _ = service.reload_stores().await;
                    }
                }
                let final_graph = native.snapshot();
                let final_snapshot = service.state.borrow().clone();
                if final_graph.ready && final_snapshot["stores"]["rules"].is_object() {
                    let final_rules = &final_snapshot["stores"]["rules"];
                    if should_advance_signature(&final_graph, final_rules, &attempted) {
                        signature = crate::automation::signature(&final_graph, final_rules);
                    }
                }
            }
        });
    }
}

#[derive(Default)]
struct PendingClearTracker {
    succeeded: std::collections::BTreeSet<(String, String)>,
    incomplete: std::collections::BTreeSet<(String, String)>,
}

impl PendingClearTracker {
    fn record_success(&mut self, entry: Option<(String, String)>) {
        if let Some(entry) = entry {
            self.succeeded.insert(entry);
        }
    }

    fn record_incomplete(&mut self, entry: Option<(String, String)>) {
        if let Some(entry) = entry {
            self.incomplete.insert(entry);
        }
    }

    fn finish(self) -> Vec<(String, String)> {
        self.succeeded
            .into_iter()
            .filter(|entry| !self.incomplete.contains(entry))
            .collect()
    }
}

fn should_advance_signature(
    graph: &crate::native::Graph,
    rules: &serde_json::Value,
    attempted: &std::collections::BTreeSet<String>,
) -> bool {
    crate::automation::routes(graph, rules)
        .iter()
        .all(|route| attempted.contains(&route.key))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::native::{Graph, MetadataValue, Node};
    use std::collections::{BTreeMap, BTreeSet};

    #[test]
    fn pending_clear_tracker_requires_every_stream_for_an_app_to_succeed() {
        let mut tracker = PendingClearTracker::default();
        tracker.record_success(Some(("firefox".into(), "playback".into())));
        tracker.record_incomplete(Some(("firefox".into(), "playback".into())));
        tracker.record_success(Some(("vlc".into(), "playback".into())));
        assert_eq!(tracker.finish(), vec![("vlc".into(), "playback".into())]);
    }

    #[test]
    fn signature_does_not_advance_when_new_streams_have_unattempted_routes() {
        let mut graph = Graph {
            connected: true,
            ready: true,
            generation: "test".into(),
            ..Graph::default()
        };
        graph.nodes.insert(
            1,
            Node {
                id: 1,
                serial: "101".into(),
                name: "output_a".into(),
                state: "Idle".into(),
                properties: BTreeMap::from([("media.class".into(), "Audio/Sink".into())]),
                ..Node::default()
            },
        );
        graph.nodes.insert(
            2,
            Node {
                id: 2,
                serial: "102".into(),
                name: "vlc".into(),
                state: "Running".into(),
                properties: BTreeMap::from([
                    ("media.class".into(), "Stream/Output/Audio".into()),
                    ("application.name".into(), "VLC".into()),
                ]),
                ..Node::default()
            },
        );
        graph.metadata_ids.insert("default".into(), 10);
        graph.metadata.insert(
            "default".into(),
            BTreeMap::from([(
                "0:default.audio.sink".into(),
                MetadataValue {
                    subject: 0,
                    key: "default.audio.sink".into(),
                    type_: "Spa:String:JSON".into(),
                    value: json!({"name": "output_a"}).to_string(),
                },
            )]),
        );
        let rules = json!({
            "appRules": [{"app": "vlc", "direction": "playback", "target": "output_a"}],
            "outputGroups": []
        });
        let mut attempted = BTreeSet::new();
        assert!(!should_advance_signature(&graph, &rules, &attempted));
        let key = crate::automation::routes(&graph, &rules)[0].key.clone();
        attempted.insert(key);
        assert!(should_advance_signature(&graph, &rules, &attempted));
    }
}
