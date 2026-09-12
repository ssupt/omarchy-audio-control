//! Whole-scene orchestration. The caller holds both the service transaction
//! barrier and the companion-compatible lock until verification completes.
use crate::adapter::{Adapter, Call};
use crate::files::FileLock;
use crate::native::{self, AudioPatch, Graph, Handle, Identity, Node};
use crate::protocol::{Failure, Result};
use crate::storage::normalize_scene;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

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

pub fn capture(native: &Handle, name: &str, overdrive: bool) -> Result<Value> {
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
        defaults[direction] = json!(if resolve(&graph, direction, &name).is_some() {
            name
        } else {
            String::new()
        });
    }
    normalize_scene(&json!({"name":name,"defaults":defaults,"devices":devices,"ports":ports,"profiles":profiles}))
        .ok_or_else(|| Failure::new("invalid_params", "A scene name is required"))
}

pub async fn apply(
    native: &Handle,
    adapter: &Adapter,
    lock: &FileLock,
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
            let change: Result<i32> = if domain == "devices" {
                device(native, step, overdrive).await
            } else if domain == "ports" {
                let graph = native.snapshot();
                if let Some(node) = resolve(&graph, text(step, "direction"), name) {
                    native
                        .select_port(identity(&graph, node), text(step, "value"))
                        .await
                        .map(|()| 0)
                        .or_else(|error| {
                            if error.code == "unavailable" {
                                Ok(3)
                            } else {
                                Err(error)
                            }
                        })
                } else {
                    Ok(3)
                }
            } else {
                let args = match domain {
                    "profiles" => vec![name.into(), text(step, "profile").into()],
                    _ => {
                        let graph = native.snapshot();
                        if let Some(node) = resolve(&graph, text(step, "direction"), name) {
                            vec![node.id.to_string(), name.into()]
                        } else {
                            result["skipped"].as_array_mut().unwrap().push(json!(name));
                            continue;
                        }
                    }
                };
                let helper = match domain {
                    "profiles" => "audio-profile-set",
                    _ if text(step, "direction") == "input" => "audio-input-set-default",
                    _ => "audio-output-set-default",
                };
                adapter
                    .run(&Call::new(helper, args), Some(lock))
                    .await
                    .map(|output| output.exit_code)
            };
            match change {
                Ok(0) => result["applied"] = json!(result["applied"].as_u64().unwrap() + 1),
                Ok(3) => result["skipped"].as_array_mut().unwrap().push(json!(name)),
                Ok(2) => {
                    result["applied"] = json!(result["applied"].as_u64().unwrap() + 1);
                    result["errors"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!(format!("{name}: preference could not be saved")));
                }
                other => {
                    result["errors"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!(format!("{name}: change could not be verified")));
                    if matches!(other, Ok(4))
                        || other.as_ref().is_err_and(|e| e.outcome == "unknown")
                    {
                        result["outcome"] = json!("unknown");
                        return Ok(result);
                    }
                }
            }
        }
        if domain == "profiles" && !steps.is_empty() {
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    }
    if !result["errors"].as_array().unwrap().is_empty() {
        result["outcome"] = json!("partial");
    }
    Ok(result)
}
async fn device(native: &Handle, step: &Value, overdrive: bool) -> Result<i32> {
    let graph = native.snapshot();
    let Some(node) = resolve(&graph, text(step, "direction"), text(step, "name")) else {
        return Ok(3);
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
        return Ok(0);
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
    Ok(1)
}
