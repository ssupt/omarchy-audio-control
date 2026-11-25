use super::{Busy, Service};
use crate::protocol::{Failure, Request, Result};
use crate::{
    files::FileLock,
    groups::{self, Change},
};
use serde_json::{Value, json};

pub(super) const PENDING_GROUP_ERROR: &str =
    "An output group change is pending while the group is in use";
const GROUP_RESTORE_ERROR: &str = "Some output groups could not be restored";

impl Service {
    pub(super) fn apply_reconcile_state(&self, result: Result<Value>) {
        match result {
            Ok(value) => {
                let pending = value
                    .get("pendingGroups")
                    .cloned()
                    .unwrap_or_else(|| json!([]));
                let has_pending = pending.as_array().is_some_and(|items| !items.is_empty());
                let failed = value
                    .get("failed")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                self.update_state(|state| {
                    state["pendingGroups"] = pending;
                    if failed {
                        state["automationError"] = json!(GROUP_RESTORE_ERROR);
                    } else if has_pending {
                        state["automationError"] = json!(PENDING_GROUP_ERROR);
                    } else if state["automationError"] == PENDING_GROUP_ERROR
                        || state["automationError"] == GROUP_RESTORE_ERROR
                    {
                        state["automationError"] = json!("");
                    }
                });
            }
            Err(_) => {
                self.update_state(|state| {
                    state["automationError"] = json!(GROUP_RESTORE_ERROR);
                });
            }
        }
    }

    pub(super) fn clear_pending_groups(&self) {
        let has_pending = self
            .state
            .borrow()
            .get("pendingGroups")
            .and_then(Value::as_array)
            .is_some_and(|items| !items.is_empty());
        if !has_pending {
            return;
        }
        self.update_state(|state| {
            state["pendingGroups"] = json!([]);
            if state["automationError"] == PENDING_GROUP_ERROR {
                state["automationError"] = json!("");
            }
        });
    }

    pub(super) async fn group_request(&self, request: &Request) -> Result<Value> {
        let change = match request.method.as_str() {
            "groups.create" => Change::Create(request.params()?),
            "groups.update" => Change::Update(request.params()?),
            "groups.delete" => Change::Delete(request.params()?),
            _ => {
                return Err(Failure::new(
                    "method_not_found",
                    "Unknown output group operation",
                ));
            }
        };
        let _transaction = self.transaction().await?;
        let _external = FileLock::mutation().await?;
        self.set_busy_for(true, &request.method);
        let _busy = Busy(self);
        let result = self.change_groups(change).await;
        if let Ok(value) = &result {
            if let Some(id) = value.get("id").and_then(Value::as_str) {
                self.update_state(|state| {
                    let cleared = if let Some(pending) = state["pendingGroups"].as_array_mut() {
                        let before = pending.len();
                        pending.retain(|item| item != id);
                        before != pending.len() && pending.is_empty()
                    } else {
                        false
                    };
                    if cleared && state["automationError"] == PENDING_GROUP_ERROR {
                        state["automationError"] = json!("");
                    }
                });
            }
        }
        self.reload_stores().await?;
        result
    }
    pub(super) async fn change_groups(&self, change: Change) -> Result<Value> {
        let native = self
            .native
            .clone()
            .ok_or_else(|| Failure::new("disconnected", "Native audio is unavailable"))?;
        let storage = self
            .storage
            .clone()
            .ok_or_else(|| Failure::new("configuration_error", "Audio rules are unavailable"))?;
        tokio::task::spawn_blocking(move || groups::apply(&native, &storage, change))
            .await
            .map_err(|_| Failure::unknown("Output group verification did not finish"))?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconcile_success_preserves_unrelated_automation_error() {
        let service = Service::new().unwrap();
        service.update_state(|s| {
            s["automationError"] = json!("An application rule could not be applied");
        });
        service.apply_reconcile_state(Ok(json!({"pendingGroups": [], "failed": false})));
        assert_eq!(
            service.state.borrow()["automationError"],
            "An application rule could not be applied"
        );
        service.update_state(|s| {
            s["automationError"] = json!(PENDING_GROUP_ERROR);
        });
        service.apply_reconcile_state(Ok(json!({"pendingGroups": [], "failed": false})));
        assert_eq!(service.state.borrow()["automationError"], "");
    }
}
