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
                if next == signature {
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
                    routes.iter().map(|(key, _)| key.clone()).collect();
                attempted.retain(|key| keys.contains(key));
                let reconcile = next_groups != groups
                    && (rules["outputGroups"]
                        .as_array()
                        .is_some_and(|g| !g.is_empty())
                        || graph
                            .nodes
                            .values()
                            .any(|n| crate::storage::group_sink(&n.name)));
                if !reconcile && routes.iter().all(|(key, _)| attempted.contains(key)) {
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
                let reconcile = next_groups != groups
                    && (rules["outputGroups"]
                        .as_array()
                        .is_some_and(|g| !g.is_empty())
                        || graph
                            .nodes
                            .values()
                            .any(|n| crate::storage::group_sink(&n.name)));
                let routes = crate::automation::routes(&graph, rules);
                groups = next_groups;
                service.set_busy(true);
                let _busy = Busy(&service);
                if reconcile
                    && service
                        .change_groups(crate::groups::Change::Reconcile)
                        .await
                        .is_err()
                {
                    service.update_state(|s| {
                        s["automationError"] = json!("Some output groups could not be restored")
                    });
                }
                let started = std::time::Instant::now();
                for (key, params) in routes {
                    if *users.borrow() == 0 || started.elapsed().as_secs() > 60 {
                        break;
                    }
                    if !attempted.insert(key) {
                        continue;
                    }
                    if let Err(error) = crate::routing::set(native, &params).await {
                        service.update_state(|s| {
                            s["automationError"] = json!("An application rule could not be applied")
                        });
                        if error.outcome == "unknown" {
                            break;
                        }
                    }
                }
            }
        });
    }
}
