//! Subscription-owned reconciliation. Lock retries never replay uncertain helpers.
use super::{Busy, Service};
use crate::adapter::Call;
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
                tokio::time::sleep(std::time::Duration::from_millis(150)).await;
                let Some(service) = weak.upgrade() else {
                    return;
                };
                let Some(native) = &service.native else {
                    return;
                };
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
                    && rules["outputGroups"]
                        .as_array()
                        .is_some_and(|g| !g.is_empty());
                if !reconcile && routes.iter().all(|(key, _)| attempted.contains(key)) {
                    signature = next_signature;
                    groups = next_groups;
                    continue;
                }
                let lock = match FileLock::mutation().await {
                    Ok(lock) => lock,
                    Err(error) => {
                        // An older release may still own a scene. Nothing was
                        // admitted: retry the lock, never an uncertain helper.
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
                // again under ownership before admitting any helper.
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
                    && rules["outputGroups"]
                        .as_array()
                        .is_some_and(|g| !g.is_empty());
                let routes = crate::automation::routes(&graph, rules);
                groups = next_groups;
                service.set_busy(true);
                let _busy = Busy(&service);
                if reconcile {
                    let result = service
                        .adapter
                        .run(
                            &Call::new("audio-output-groups", vec!["reconcile".into()]),
                            Some(&lock),
                        )
                        .await;
                    if result.is_err() || result.as_ref().is_ok_and(|o| o.exit_code != 0) {
                        service.update_state(|s| {
                            s["automationError"] = json!("Some output groups could not be restored")
                        });
                    }
                }
                let started = std::time::Instant::now();
                for (key, args) in routes {
                    if *users.borrow() == 0 || started.elapsed().as_secs() > 60 {
                        break;
                    }
                    if !attempted.insert(key) {
                        continue;
                    }
                    let result = service
                        .adapter
                        .run(&Call::new("audio-stream-route-set", args), Some(&lock))
                        .await;
                    if result.is_err() || result.as_ref().is_ok_and(|o| o.exit_code != 0) {
                        service.update_state(|s| {
                            s["automationError"] = json!("An application rule could not be applied")
                        });
                        // An unknown adapter outcome stops the batch.
                        if result.is_err() || result.as_ref().is_ok_and(|o| o.exit_code == 4) {
                            break;
                        }
                    }
                }
            }
        });
    }
}
