//! Compatibility helpers and the saved-rule update paired with a manual route.
use super::{Busy, Service};
use crate::PROTOCOL_VERSION;
use crate::adapter::Call;
use crate::files::FileLock;
use crate::protocol::{Failure, Request, Result};
use serde_json::{Value, json};

impl Service {
    pub(super) async fn adapter_request(&self, request: &Request) -> Result<Value> {
        let call = request.params::<Call>()?;
        call.validate()?;
        if call.helper == "audio-diagnostics" {
            return Err(Failure::new(
                "invalid_params",
                "Use diagnostics.refresh to collect a shared report",
            ));
        }
        let _transaction = self.transaction().await?;
        if call.mutating() {
            let graph = self.native.as_ref().map(|native| native.snapshot());
            if graph.as_ref().is_none_or(|g| {
                !g.ready || call.generation.is_empty() || g.generation != call.generation
            }) {
                return Err(Failure::new(
                    "stale_graph",
                    "Audio graph changed before this operation started",
                ));
            }
        }
        let lock = if call.mutating() {
            Some(FileLock::mutation().await?)
        } else {
            None
        };
        self.set_busy(call.mutating());
        let _busy = Busy(self);
        // Updating a ruled application's manual route and its saved
        // rule is one operation, before automatic reconciliation resumes.
        let rule_update = if call.helper == "audio-stream-route-set" {
            self.native.as_ref().and_then(|native| {
                let graph = native.snapshot();
                let stream = graph.nodes.values().find(|n| n.serial == call.args[1])?;
                let app = crate::automation::app(stream);
                let snapshot = self.state.borrow();
                snapshot["stores"]["rules"]["appRules"]
                    .as_array()?
                    .iter()
                    .find(|r| r["app"] == app && r["direction"] == call.args[0])?;
                let target = graph.nodes.values().find(|n| n.serial == call.args[2])?;
                let following = call.args.get(3).is_some_and(|m| m == "default");
                Some(Request {
                    version: PROTOCOL_VERSION,
                    id: "route-rule".into(),
                    method: if following {
                        "rules.delete_app"
                    } else {
                        "rules.set_app"
                    }
                    .into(),
                    params: if following {
                        json!({"app":app,"direction":call.args[0]})
                    } else {
                        json!({"app":app,"direction":call.args[0],"target":target.name})
                    },
                })
            })
        } else {
            None
        };
        let mut output = self.adapter.run(&call, lock.as_ref()).await?;
        if output.exit_code == 0 {
            if let (Some(update), Some(storage)) = (rule_update, self.storage.clone()) {
                let saved = tokio::task::spawn_blocking(move || storage.handle(&update)).await;
                if !matches!(saved, Ok(Ok(Some(_)))) {
                    output.exit_code = 2;
                    output.outcome = "persistence_failed";
                }
            }
        }
        if call.mutating() {
            self.reload_stores().await?;
        }
        Ok(serde_json::to_value(output).unwrap())
    }
}
