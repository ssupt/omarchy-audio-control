//! Manual routes update an existing application rule before automation resumes.
use super::{Busy, Service};
use crate::files::FileLock;
use crate::native;
use crate::protocol::{Failure, Request, Result};
use crate::storage::Kind;
use crate::{defaults, routing};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CompatDefault {
    direction: String,
    id: u32,
    name: String,
    previous: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeleteAppRule {
    app: String,
    direction: String,
}

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
        let result = match request.method.as_str() {
            "default.set" => {
                defaults::select(native, self.storage.as_ref(), request.params()?).await
            }
            "default.compat" => self.compat_default(native, request.params()?).await,
            "rules.delete_app" => self.delete_app_rule(native, request.params()?).await,
            _ => self.route_application(native, request.params()?).await,
        };
        self.reload_stores().await?;
        result
    }

    /// Accept the old Bluetooth panel's node ID and name without letting a
    /// stale or recycled ID select another device. The normal transaction then
    /// preserves applications following the previous default.
    async fn compat_default(
        &self,
        native: &native::Handle,
        params: CompatDefault,
    ) -> Result<Value> {
        let direction = match params.direction.as_str() {
            "output" => routing::Direction::Playback,
            "input" => routing::Direction::Recording,
            _ => return Err(Failure::new("invalid_params", "Invalid audio direction")),
        };
        if params.name.is_empty() || params.name.len() > 160 || params.previous.len() > 160 {
            return Err(Failure::new(
                "invalid_params",
                "Invalid audio endpoint name",
            ));
        }
        let graph = native.snapshot();
        let target = graph
            .nodes
            .get(&params.id)
            .ok_or_else(|| Failure::new("unavailable", "Audio endpoint disappeared"))?;
        if target.name != params.name || routing::endpoint_direction(target) != Some(direction) {
            return Err(Failure::new(
                "conflict",
                "Audio endpoint changed before selection",
            ));
        }
        let current = routing::default_name(&graph, direction);
        if !params.previous.is_empty() && current.as_deref() != Some(&params.previous) {
            return Err(Failure::new("conflict", "The default audio device changed"));
        }
        let mut previous = graph
            .nodes
            .values()
            .filter(|node| Some(node.name.as_str()) == current.as_deref());
        let previous = previous.next().map(|node| routing::identity(&graph, node));
        // defaults::select also checks this after acquiring its preference lock.
        defaults::select(
            native,
            self.storage.as_ref(),
            defaults::Set {
                identity: routing::identity(&graph, target),
                previous,
            },
        )
        .await
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
        let had_pending = rules["pendingDefaultRoutes"]
            .as_array()
            .is_some_and(|pending| {
                pending
                    .iter()
                    .any(|entry| entry["app"] == app && entry["direction"] == direction.name())
            });
        routing::set(native, &params).await?;
        if previous_rule.is_some() || had_pending {
            let saved = tokio::task::spawn_blocking(move || {
                storage.update(Kind::Rules, |store| {
                    if let Some(previous_rule) = previous_rule {
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
                    }
                    crate::storage::set_pending_default(store, &app, direction.name(), false);
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

    async fn delete_app_rule(
        &self,
        native: &native::Handle,
        params: DeleteAppRule,
    ) -> Result<Value> {
        let app = crate::storage::label(&json!(params.app), 120).to_ascii_lowercase();
        if app.is_empty() {
            return Err(Failure::new(
                "invalid_params",
                "Invalid audio configuration change",
            ));
        }
        let direction = match params.direction.as_str() {
            "playback" => routing::Direction::Playback,
            "recording" => routing::Direction::Recording,
            _ => {
                return Err(Failure::new(
                    "invalid_params",
                    "Invalid audio configuration change",
                ));
            }
        };
        let storage = self.storage.clone().ok_or_else(|| {
            Failure::new("configuration_error", "Application rules are unavailable")
        })?;
        let app_for_delete = app.clone();
        let writer = storage.clone();
        let had_rule = tokio::task::spawn_blocking(move || {
            let mut existed = false;
            writer.update(Kind::Rules, |store| {
                let rules = store["appRules"].as_array_mut().unwrap();
                let before = rules.len();
                rules.retain(|r| r["app"] != app_for_delete || r["direction"] != direction.name());
                existed = rules.len() != before;
                if existed {
                    crate::storage::set_pending_default(
                        store,
                        &app_for_delete,
                        direction.name(),
                        true,
                    );
                }
                Ok(())
            })?;
            Ok::<_, Failure>(existed)
        })
        .await
        .map_err(|_| Failure::unknown("Store operation stopped unexpectedly"))??;

        let graph = native.snapshot();
        if graph.ready && graph.connected {
            let default_target = routing::default_name(&graph, direction).and_then(|name| {
                let mut matches = graph.nodes.values().filter(|n| {
                    routing::endpoint_direction(n) == Some(direction)
                        && n.name == name
                        && !n.serial.is_empty()
                });
                let target = matches.next()?;
                matches
                    .next()
                    .is_none()
                    .then(|| routing::identity(&graph, target))
            });
            let matching_streams: Vec<_> = graph
                .nodes
                .values()
                .filter(|n| {
                    routing::stream_direction(n) == Some(direction)
                        && !n.serial.is_empty()
                        && crate::automation::app(n) == app
                })
                .map(|n| routing::identity(&graph, n))
                .collect();
            if let Some(target) = default_target {
                if !matching_streams.is_empty() {
                    let mut cleared_any = false;
                    let mut all_cleared = true;
                    for stream in matching_streams {
                        let set = routing::Set {
                            identity: stream.clone(),
                            target: target.clone(),
                            mode: routing::Mode::Default,
                        };
                        match routing::set(native, &set).await {
                            Ok(()) => cleared_any = true,
                            Err(error)
                                if error.code == "stale_node"
                                    && native
                                        .snapshot()
                                        .nodes
                                        .get(&stream.id)
                                        .is_none_or(|node| node.serial != stream.serial) => {}
                            Err(_) => all_cleared = false,
                        }
                    }
                    if cleared_any && all_cleared && had_rule {
                        let app_for_clear = app.clone();
                        let _ = tokio::task::spawn_blocking(move || {
                            storage.update(Kind::Rules, |store| {
                                crate::storage::set_pending_default(
                                    store,
                                    &app_for_clear,
                                    direction.name(),
                                    false,
                                );
                                Ok(())
                            })
                        })
                        .await;
                    }
                }
            }
        }
        Ok(json!({"outcome": "applied"}))
    }
}
