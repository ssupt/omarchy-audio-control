//! Manual routes update an existing application rule before automation resumes.
use super::{Busy, Service};
use crate::files::FileLock;
use crate::native;
use crate::protocol::{Failure, Request, Result};
use crate::storage::Kind;
use crate::{defaults, routing};
use serde_json::{Value, json};

impl Service {
    pub(super) async fn routing_request(&self, request: &Request) -> Result<Value> {
        let native = self
            .native
            .as_ref()
            .ok_or_else(|| Failure::new("disconnected", "Native audio is unavailable"))?;
        let _transaction = self.transaction().await?;
        let _external_lock = FileLock::mutation().await?;
        self.set_busy_for(true, &request.method);
        let _busy = Busy(self);
        let result = if request.method == "default.set" {
            defaults::select(native, self.storage.as_ref(), request.params()?).await
        } else {
            self.route_application(native, request.params()?).await
        };
        self.reload_stores().await?;
        result
    }

    async fn route_application(
        &self,
        native: &native::Handle,
        params: routing::Set,
    ) -> Result<Value> {
        let graph = native.snapshot();
        let stream = native::validate_identity(&graph, &params.identity)?;
        let app = crate::automation::app(stream);
        let direction = routing::stream_direction(stream)
            .ok_or_else(|| Failure::new("invalid_target", "Node is not an application stream"))?;
        let target = routing::endpoint(&graph, &params.target, direction)?
            .name
            .clone();
        let storage = self.storage.clone().ok_or_else(|| {
            Failure::new("configuration_error", "Application rules are unavailable")
        })?;
        let reader = storage.clone();
        let rules = tokio::task::spawn_blocking(move || reader.read(Kind::Rules))
            .await
            .map_err(|_| Failure::new("internal_error", "Could not read application rules"))??;
        let previous_rule = rules["appRules"]
            .as_array()
            .and_then(|rules| {
                rules
                    .iter()
                    .find(|r| r["app"] == app && r["direction"] == direction.name())
            })
            .cloned();
        routing::set(native, &params).await?;
        if let Some(previous_rule) = previous_rule {
            let saved = tokio::task::spawn_blocking(move || {
                storage.update(Kind::Rules, |store| {
                    let rules = store["appRules"].as_array_mut().unwrap();
                    let current = rules
                        .iter()
                        .find(|r| r["app"] == app && r["direction"] == direction.name());
                    // Preserve external edits, including removal of the rule.
                    if current.is_some_and(|r| r != &previous_rule) {
                        return Err(Failure::new(
                            "conflict",
                            "Application rule changed during routing",
                        ));
                    }
                    if params.mode == routing::Mode::Default {
                        rules.retain(|r| r["app"] != app || r["direction"] != direction.name());
                    } else if let Some(rule) = rules
                        .iter_mut()
                        .find(|r| r["app"] == app && r["direction"] == direction.name())
                    {
                        rule["target"] = json!(target);
                    }
                    Ok(())
                })
            })
            .await;
            if !matches!(saved, Ok(Ok(_))) {
                return Ok(
                    json!({"outcome":"persistence_failed", "message":"Application route changed, but its saved rule could not be updated"}),
                );
            }
        }
        Ok(json!({"outcome":"applied"}))
    }
}
