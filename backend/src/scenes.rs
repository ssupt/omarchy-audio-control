//! Whole-scene orchestration. The caller holds both the service transaction
//! barrier and the companion-compatible lock until verification completes.
use crate::native::{self, AudioPatch, Graph, Handle, Identity, Node};
use crate::protocol::{Failure, Result};
use crate::storage::normalize_scene;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

enum StepOutcome {
    Applied,
    Restored,
    Skipped,
    PersistenceFailed,
}

fn class(node: &Node) -> &str {
    node.properties
        .get("media.class")
        .map(String::as_str)
        .unwrap_or("")
}
fn eligible(node: &Node, direction: &str) -> bool {
    let name = node.name.to_ascii_lowercase();
    class(node)
        == if direction == "output" {
            "Audio/Sink"
        } else {
            "Audio/Source"
        }
        && !node.serial.is_empty()
        && !node.audio.volumes.is_empty()
        && name != "quickshell"
        && !name.ends_with(".monitor")
        && ![
            "omarchy_audio_test",
            "omarchy_speaker_tuning",
            "omarchy_audio_group_",
            "output.omarchy_audio_group_",
        ]
        .iter()
        .any(|prefix| name.starts_with(prefix))
        && node
            .properties
            .get("application.id")
            .is_none_or(|id| id != "ssupt.audio-control")
        && node
            .properties
            .get("device.class")
            .is_none_or(|value| !value.eq_ignore_ascii_case("monitor"))
}
fn resolve<'a>(graph: &'a Graph, direction: &str, name: &str) -> Option<&'a Node> {
    if !graph.ready {
        return None;
    }
    let mut matches = graph
        .nodes
        .values()
        .filter(|node| node.name == name && eligible(node, direction));
    let node = matches.next()?;
    if matches.next().is_some() {
        None
    } else {
        Some(node)
    }
}
fn physical_group_member(node: &Node) -> bool {
    crate::routing::endpoint_direction(node) == Some(crate::routing::Direction::Playback)
        && !crate::storage::group_sink(&node.name)
        && node
            .properties
            .get("application.id")
            .is_none_or(|v| v != "ssupt.audio-control")
        && !node
            .properties
            .get("node.virtual")
            .is_some_and(|v| matches!(v.as_str(), "true" | "1"))
        && !node
            .properties
            .get("device.class")
            .is_some_and(|v| matches!(v.as_str(), "filter" | "monitor"))
        && !node
            .properties
            .get("factory.name")
            .is_some_and(|v| matches!(v.as_str(), "support.null-audio-sink" | "filter-chain"))
}
fn group_members_ready(graph: &Graph, id: &str, sink_name: &str, rules: Option<&Value>) -> bool {
    let Some(rules) = rules else {
        return false;
    };
    let Some(group) = rules["outputGroups"].as_array().and_then(|groups| {
        groups
            .iter()
            .find(|g| g["id"] == id && g["sink"] == sink_name)
    }) else {
        return false;
    };
    let Some(members) = group["members"].as_array().filter(|m| m.len() >= 2) else {
        return false;
    };
    members.iter().all(|member| {
        let Some(member_name) = member.as_str() else {
            return false;
        };
        let mut matches = graph
            .nodes
            .values()
            .filter(|n| n.name == member_name && physical_group_member(n));
        matches.next().is_some() && matches.next().is_none()
    })
}
fn owned_group_available(graph: &Graph, node: &Node, rules: Option<&Value>) -> bool {
    let Some(id) = node
        .name
        .strip_prefix("omarchy_audio_group_")
        .filter(|id| crate::storage::group_id(id))
    else {
        return false;
    };
    let owned = node
        .properties
        .get("application.id")
        .is_some_and(|v| v == "ssupt.audio-control")
        && node
            .properties
            .get("omarchy.audio.group.id")
            .is_some_and(|v| v == id)
        && node
            .properties
            .get("node.virtual")
            .is_some_and(|v| matches!(v.as_str(), "true" | "1"));
    owned && group_members_ready(graph, id, &node.name, rules)
}
fn resolve_default<'a>(
    graph: &'a Graph,
    direction: &str,
    name: &str,
    rules: Option<&Value>,
) -> Option<&'a Node> {
    if !graph.ready || !graph.connected || name.is_empty() {
        return None;
    }
    let dir = match direction {
        "output" => crate::routing::Direction::Playback,
        "input" => crate::routing::Direction::Recording,
        _ => return None,
    };
    let mut matches = graph.nodes.values().filter(|node| node.name == name);
    let node = matches.next()?;
    if matches.next().is_some() {
        return None;
    }
    crate::routing::endpoint(graph, &identity(graph, node), dir).ok()?;
    if crate::storage::group_sink(&node.name) && !owned_group_available(graph, node, rules) {
        return None;
    }
    Some(node)
}
fn identity(graph: &Graph, node: &Node) -> Identity {
    Identity {
        generation: graph.generation.clone(),
        id: node.id,
        serial: node.serial.clone(),
    }
}
fn stereo(node: &Node) -> Option<(usize, usize)> {
    let left = node.audio.channels.iter().position(|c| *c == 3);
    let right = node.audio.channels.iter().position(|c| *c == 4);
    match (left, right) {
        (Some(l), Some(r)) if l < node.audio.volumes.len() && r < node.audio.volumes.len() => {
            Some((l, r))
        }
        _ if node.audio.volumes.len() == 2 => Some((0, 1)),
        _ => None,
    }
}
fn peak(values: &[f64]) -> f64 {
    values.iter().copied().fold(0.0, f64::max)
}
fn close(a: &[f64], b: &[f64]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| (x - y).abs() < 0.015)
}
fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
fn default_name(graph: &Graph, direction: &str) -> String {
    let key = if direction == "input" {
        "default.audio.source"
    } else {
        "default.audio.sink"
    };
    graph
        .metadata
        .get("default")
        .into_iter()
        .flat_map(|values| values.values())
        .find(|value| value.subject == 0 && value.key == key)
        .and_then(|value| serde_json::from_str::<Value>(&value.value).ok())
        .and_then(|value| value["name"].as_str().map(str::to_owned))
        .unwrap_or_default()
}

pub fn capture(
    native: &Handle,
    rules: Option<&Value>,
    name: &str,
    overdrive: bool,
) -> Result<Value> {
    let graph = native.snapshot();
    if !native::catalog::ready(&graph) {
        return Err(Failure::new("busy", "Audio device information is updating"));
    }
    let (profiles, ports) = native::catalog::snapshot(&graph);
    let devices: Vec<_> = graph.nodes.values().filter_map(|node| {
        let direction = if class(node) == "Audio/Sink" { "output" } else { "input" };
        resolve(&graph, direction, &node.name)?;
        let balance = stereo(node).map(|(l,r)| {
            let (l,r) = (node.audio.volumes[l], node.audio.volumes[r]);
            if l.max(r) == 0.0 { 0.0 } else { (r-l) / l.max(r) }
        }).unwrap_or(0.0);
        Some(json!({"name": node.name, "direction": direction,
            "volume": peak(&node.audio.volumes).min(if direction == "output" && !overdrive { 1.0 } else { 1.5 }),
            "muted": direction == "input" && node.audio.muted == Some(true), "balance": balance}))
    }).take(64).collect();
    let ports: Vec<_> = ports.as_array().ok_or_else(|| Failure::new("capture_failed", "Invalid port list"))?.iter()
        .map(|p| json!({"direction":p["direction"], "endpoint":p["endpoint"], "value":p["activePort"]})).collect();
    let profiles: Vec<_> = profiles
        .as_array()
        .ok_or_else(|| Failure::new("capture_failed", "Invalid profile list"))?
        .iter()
        .map(|p| json!({"card":p["name"], "profile":p["activeProfile"]}))
        .collect();
    let mut defaults = json!({});
    for direction in ["output", "input"] {
        let name = default_name(&graph, direction);
        defaults[direction] = json!(
            if resolve_default(&graph, direction, &name, rules).is_some() {
                name
            } else {
                String::new()
            }
        );
    }
    normalize_scene(&json!({"name":name,"defaults":defaults,"devices":devices,"ports":ports,"profiles":profiles}))
        .ok_or_else(|| Failure::new("invalid_params", "A scene name is required"))
}

pub async fn apply(
    native: &Handle,
    storage: Option<&crate::storage::Storage>,
    rules: Option<&Value>,
    raw: &Value,
    overdrive: bool,
) -> Result<Value> {
    let scene =
        normalize_scene(raw).ok_or_else(|| Failure::new("invalid_params", "Invalid scene"))?;
    let mut result =
        json!({"name":scene["name"], "applied":0, "skipped":[], "errors":[], "outcome":"applied"});
    let started = Instant::now();
    for domain in ["profiles", "ports", "devices", "defaults"] {
        let defaults =
            ["output", "input"].map(|d| json!({"direction":d,"name":scene["defaults"][d]}));
        let steps = if domain == "defaults" {
            defaults.as_slice()
        } else {
            scene[domain].as_array().unwrap().as_slice()
        };
        for step in steps {
            if started.elapsed() > Duration::from_secs(75) {
                result["errors"].as_array_mut().unwrap().push(json!(
                    "Scene deadline reached; remaining steps were not started"
                ));
                result["outcome"] = json!("partial");
                return Ok(result);
            }
            let name = match domain {
                "profiles" => text(step, "card"),
                "ports" => text(step, "endpoint"),
                _ => text(step, "name"),
            };
            if name.is_empty() {
                continue;
            }
            let change: Result<StepOutcome> = if domain == "devices" {
                device(native, step, overdrive).await
            } else if domain == "profiles" {
                let graph = native.snapshot();
                if let Some(identity) = native::catalog::profile_identity(&graph, name) {
                    crate::profiles::select(native, storage, identity, text(step, "profile"))
                        .await
                        .map(|value| {
                            if value["outcome"] == "persistence_failed" {
                                StepOutcome::PersistenceFailed
                            } else {
                                StepOutcome::Applied
                            }
                        })
                        .or_else(|error| {
                            if error.code == "unavailable" {
                                Ok(StepOutcome::Skipped)
                            } else {
                                Err(error)
                            }
                        })
                } else {
                    Ok(StepOutcome::Skipped)
                }
            } else if domain == "ports" {
                let graph = native.snapshot();
                if let Some(identity) =
                    native::catalog::port_identity(&graph, text(step, "direction"), name)
                {
                    native
                        .select_port(identity, text(step, "value"))
                        .await
                        .map(|()| StepOutcome::Applied)
                        .or_else(|error| {
                            if error.code == "unavailable" {
                                Ok(StepOutcome::Skipped)
                            } else {
                                Err(error)
                            }
                        })
                } else {
                    Ok(StepOutcome::Skipped)
                }
            } else {
                let direction = text(step, "direction");
                let mut graph = native.snapshot();
                if direction == "output"
                    && resolve_default(&graph, direction, name, rules).is_none()
                    && started.elapsed() <= Duration::from_secs(70)
                {
                    if let (Some(storage), Some(group_id)) = (
                        storage,
                        name.strip_prefix("omarchy_audio_group_")
                            .filter(|id| crate::storage::group_id(id)),
                    ) {
                        if group_members_ready(&graph, group_id, name, rules) {
                            let native_for_reconcile = native.clone();
                            let storage_for_reconcile = storage.clone();
                            if matches!(
                                tokio::task::spawn_blocking(move || {
                                    crate::groups::apply(
                                        &native_for_reconcile,
                                        &storage_for_reconcile,
                                        crate::groups::Change::Reconcile,
                                    )
                                })
                                .await,
                                Ok(Ok(_))
                            ) {
                                let mut state = native.subscribe();
                                let _ = tokio::time::timeout(Duration::from_secs(2), async {
                                    loop {
                                        if resolve_default(
                                            &state.borrow_and_update(),
                                            direction,
                                            name,
                                            rules,
                                        )
                                        .is_some()
                                        {
                                            break;
                                        }
                                        if state.changed().await.is_err() {
                                            break;
                                        }
                                    }
                                })
                                .await;
                                graph = native.snapshot();
                            }
                        }
                    }
                }
                let Some(node) = resolve_default(&graph, direction, name, rules) else {
                    result["skipped"].as_array_mut().unwrap().push(json!(name));
                    continue;
                };
                crate::defaults::select(
                    native,
                    storage,
                    crate::defaults::Set {
                        identity: identity(&graph, node),
                        previous: None,
                    },
                )
                .await
                .map(|value| {
                    if value["outcome"] == "persistence_failed" {
                        StepOutcome::PersistenceFailed
                    } else {
                        StepOutcome::Applied
                    }
                })
            };
            match change {
                Ok(StepOutcome::Applied) => {
                    result["applied"] = json!(result["applied"].as_u64().unwrap() + 1)
                }
                Ok(StepOutcome::Skipped) => {
                    result["skipped"].as_array_mut().unwrap().push(json!(name))
                }
                Ok(StepOutcome::PersistenceFailed) => {
                    result["applied"] = json!(result["applied"].as_u64().unwrap() + 1);
                    result["errors"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!(format!("{name}: preference could not be saved")));
                }
                Ok(StepOutcome::Restored) => {
                    result["errors"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!(format!("{name}: change was restored")));
                }
                Err(error) => {
                    result["errors"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!(format!("{name}: change could not be verified")));
                    if error.outcome == "unknown" {
                        result["outcome"] = json!("unknown");
                        return Ok(result);
                    }
                }
            }
        }
    }
    if !result["errors"].as_array().unwrap().is_empty() {
        result["outcome"] = json!("partial");
    }
    Ok(result)
}
async fn device(native: &Handle, step: &Value, overdrive: bool) -> Result<StepOutcome> {
    let graph = native.snapshot();
    let Some(node) = resolve(&graph, text(step, "direction"), text(step, "name")) else {
        return Ok(StepOutcome::Skipped);
    };
    let identity = identity(&graph, node);
    let volume = step["volume"].as_f64().unwrap().min(
        if text(step, "direction") == "output" && !overdrive {
            1.0
        } else {
            1.5
        },
    );
    let mut levels = vec![volume; node.audio.volumes.len()];
    if let Some((left, right)) = stereo(node) {
        let balance = step["balance"].as_f64().unwrap();
        levels[left] *= if balance > 0.0 { 1.0 - balance } else { 1.0 };
        levels[right] *= if balance < 0.0 { 1.0 + balance } else { 1.0 };
    }
    let muted = text(step, "direction") == "input" && step["muted"] == true;
    let change = async {
        native
            .patch(
                identity.clone(),
                AudioPatch {
                    muted: Some(true),
                    volumes: Some(levels.clone()),
                },
            )
            .await?;
        native
            .patch(
                identity.clone(),
                AudioPatch {
                    muted: Some(muted),
                    volumes: None,
                },
            )
            .await
    }
    .await;
    if change.is_ok() {
        return Ok(StepOutcome::Applied);
    }
    let current = native.snapshot();
    let live = native::validate_identity(&current, &identity)?;
    // Avoid overwriting an unrelated external level change during recovery.
    if !close(&live.audio.volumes, &levels) && !close(&live.audio.volumes, &node.audio.volumes) {
        return Err(Failure::unknown(
            "Device changed externally during scene recovery",
        ));
    }
    native
        .patch(
            identity.clone(),
            AudioPatch {
                muted: Some(true),
                volumes: Some(node.audio.volumes.clone()),
            },
        )
        .await?;
    native
        .patch(
            identity,
            AudioPatch {
                muted: node.audio.muted,
                volumes: None,
            },
        )
        .await?;
    Ok(StepOutcome::Restored)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn node(id: u32, name: &str, class: &str) -> Node {
        Node {
            id,
            serial: (id + 100).to_string(),
            name: name.into(),
            state: "Idle".into(),
            properties: BTreeMap::from([("media.class".into(), class.into())]),
            ..Node::default()
        }
    }

    #[test]
    fn scene_defaults_accept_owned_healthy_groups_and_reject_foreign_or_degraded_ones() {
        let group_id = "0123456789abcdef";
        let group_sink = format!("omarchy_audio_group_{group_id}");
        let mut graph = Graph {
            connected: true,
            ready: true,
            generation: "test".into(),
            ..Graph::default()
        };
        graph.nodes.insert(1, node(1, "left", "Audio/Sink"));
        graph.nodes.insert(2, node(2, "right", "Audio/Sink"));
        let mut group = node(3, &group_sink, "Audio/Sink");
        group
            .properties
            .insert("application.id".into(), "ssupt.audio-control".into());
        group
            .properties
            .insert("omarchy.audio.group.id".into(), group_id.into());
        group
            .properties
            .insert("node.virtual".into(), "true".into());
        graph.nodes.insert(3, group);

        let rules = json!({
            "outputGroups": [{
                "id": group_id,
                "name": "Desk",
                "sink": group_sink,
                "members": ["left", "right"]
            }]
        });
        assert!(resolve_default(&graph, "output", &group_sink, Some(&rules)).is_some());
        // Missing rules must fail closed instead of accepting an unverified group sink.
        assert!(resolve_default(&graph, "output", &group_sink, None).is_none());
        // Physical device-volume capture still excludes the virtual group sink.
        assert!(resolve(&graph, "output", &group_sink).is_none());

        // Virtual/null-sink member does not qualify as a healthy physical group member.
        graph
            .nodes
            .get_mut(&2)
            .unwrap()
            .properties
            .insert("factory.name".into(), "support.null-audio-sink".into());
        assert!(resolve_default(&graph, "output", &group_sink, Some(&rules)).is_none());
        graph
            .nodes
            .get_mut(&2)
            .unwrap()
            .properties
            .remove("factory.name");

        // Missing member degrades the group, so scene default skips it.
        graph.nodes.remove(&2);
        assert!(resolve_default(&graph, "output", &group_sink, Some(&rules)).is_none());

        // Foreign node with the reserved name is never accepted as an owned group.
        graph.nodes.insert(2, node(2, "right", "Audio/Sink"));
        graph
            .nodes
            .get_mut(&3)
            .unwrap()
            .properties
            .remove("application.id");
        assert!(resolve_default(&graph, "output", &group_sink, Some(&rules)).is_none());
    }
}
