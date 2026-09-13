//! Application targets use WirePlumber metadata; live links confirm the result.
use crate::native::metadata::{self, Batch, Change};
use crate::native::{self, Graph, Handle, Identity, MetadataValue, Node};
use crate::protocol::{Failure, Result};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Playback,
    Recording,
}
impl Direction {
    pub fn name(self) -> &'static str {
        match self {
            Self::Playback => "playback",
            Self::Recording => "recording",
        }
    }
    pub fn preference(self) -> &'static str {
        match self {
            Self::Playback => "output",
            Self::Recording => "input",
        }
    }
    pub fn endpoint_class(self) -> &'static str {
        match self {
            Self::Playback => "Audio/Sink",
            Self::Recording => "Audio/Source",
        }
    }
    pub fn default_key(self) -> &'static str {
        match self {
            Self::Playback => "default.audio.sink",
            Self::Recording => "default.audio.source",
        }
    }
    pub fn configured_key(self) -> &'static str {
        match self {
            Self::Playback => "default.configured.audio.sink",
            Self::Recording => "default.configured.audio.source",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Override,
    Default,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Set {
    pub identity: Identity,
    pub target: Identity,
    pub mode: Mode,
}

pub fn class(node: &Node) -> &str {
    node.properties
        .get("media.class")
        .map(String::as_str)
        .unwrap_or("")
}
pub fn identity(graph: &Graph, node: &Node) -> Identity {
    Identity {
        generation: graph.generation.clone(),
        id: node.id,
        serial: node.serial.clone(),
    }
}
fn internal(node: &Node) -> bool {
    let name = node.name.to_ascii_lowercase();
    name == "quickshell"
        || name.starts_with("omarchy_audio_test")
        || name.starts_with("omarchy_speaker_tuning")
        || node
            .properties
            .get("application.id")
            .is_some_and(|v| v == "ssupt.audio-control")
}
pub fn stream_direction(node: &Node) -> Option<Direction> {
    if internal(node)
        || node.properties.contains_key("pulse.module.id")
        || node.name.starts_with("output.omarchy_audio_group_")
        || node.name.starts_with("omarchy_audio_group_")
    {
        return None;
    }
    match class(node) {
        "Stream/Output/Audio" => Some(Direction::Playback),
        "Stream/Input/Audio" => Some(Direction::Recording),
        _ => None,
    }
}
pub fn endpoint_direction(node: &Node) -> Option<Direction> {
    let group_sink = class(node) == "Audio/Sink" && crate::storage::group_sink(&node.name);
    if (internal(node) && !group_sink)
        || node.name.ends_with(".monitor")
        || node
            .properties
            .get("device.class")
            .is_some_and(|v| v.eq_ignore_ascii_case("monitor"))
    {
        return None;
    }
    match class(node) {
        "Audio/Sink" => Some(Direction::Playback),
        "Audio/Source" | "Audio/Source/Virtual" => Some(Direction::Recording),
        _ => None,
    }
}
pub fn endpoint<'a>(graph: &'a Graph, target: &Identity, direction: Direction) -> Result<&'a Node> {
    let node = native::validate_identity(graph, target)?;
    if endpoint_direction(node) != Some(direction)
        || node.serial.parse::<u64>().is_err()
        || node.name.is_empty()
        || crate::storage::identifier(&json!(node.name), 160) != node.name
        || graph.nodes.values().filter(|n| n.name == node.name).count() != 1
    {
        return Err(Failure::new(
            "invalid_target",
            "Audio endpoint is unavailable or ambiguous",
        ));
    }
    Ok(node)
}
pub fn default_name(graph: &Graph, direction: Direction) -> Option<String> {
    let raw = metadata::value(graph, "default", direction.default_key())?;
    serde_json::from_str::<Value>(&raw.value).ok()?["name"]
        .as_str()
        .map(str::to_owned)
}
pub fn target<'a>(
    graph: &'a Graph,
    stream: &Node,
    direction: Direction,
) -> Result<Option<&'a Node>> {
    let ids: BTreeSet<_> = graph
        .links
        .values()
        .filter_map(|link| {
            if !matches!(link.state.as_str(), "Active" | "Paused") {
                return None;
            }
            match direction {
                Direction::Playback if link.output_node == stream.id => Some(link.input_node),
                Direction::Recording if link.input_node == stream.id => Some(link.output_node),
                _ => None,
            }
        })
        .collect();
    if ids.len() > 1 {
        return Err(Failure::new(
            "unsupported",
            "Application has multiple audio targets",
        ));
    }
    Ok(ids.first().and_then(|id| graph.nodes.get(id)))
}
pub fn explicit(graph: &Graph, stream: &Node) -> Result<bool> {
    if !graph.metadata_ids.contains_key("default") {
        return Err(Failure::new(
            "unavailable",
            "Application routing metadata is unavailable",
        ));
    }
    let mut explicit = false;
    let mut has_metadata = false;
    for key in ["target.object", "target.node"] {
        if let Some(raw) = metadata::subject_value(graph, "default", stream.id, key) {
            has_metadata = true;
            if raw.value == "-1" {
                continue;
            }
            if raw.value.is_empty()
                || (raw.value.parse::<u64>().is_err()
                    && (key == "target.node"
                        || raw.value.parse::<f64>().is_ok()
                        || crate::storage::identifier(&json!(raw.value), 160) != raw.value))
            {
                return Err(Failure::new(
                    "unsupported",
                    "Application routing metadata is invalid",
                ));
            }
            explicit = true;
        }
    }
    // WirePlumber falls back to a target declared by the application when no
    // metadata override exists. Preserve that route when changing defaults.
    Ok(explicit
        || (!has_metadata
            && ["target.object", "node.target"].iter().any(|key| {
                stream
                    .properties
                    .get(*key)
                    .is_some_and(|value| !value.is_empty() && value != "-1")
            })))
}
pub fn movable(graph: &Graph, stream: &Node) -> Result<()> {
    if ["node.dont-move", "node.dont-reconnect"]
        .iter()
        .any(|k| stream.properties.get(*k).is_some_and(|v| v == "true"))
        || metadata::value(graph, "sm-settings", "linking.allow-moving-streams")
            .is_some_and(|v| v.value == "false")
    {
        return Err(Failure::new(
            "unsupported",
            "This application does not allow audio routing changes",
        ));
    }
    Ok(())
}
pub fn snapshot(graph: &Graph) -> Value {
    let mut routes = json!({"playback":{}, "recording":{}, "error":""});
    if !graph.ready || !graph.connected || !graph.metadata_ids.contains_key("default") {
        routes["error"] = json!("Application routes are unavailable");
        return routes;
    }
    for stream in graph.nodes.values() {
        let Some(direction) = stream_direction(stream) else {
            continue;
        };
        if stream.serial.parse::<u64>().is_err() {
            continue;
        }
        if routes[direction.name()].as_object().unwrap().len() >= 512 {
            routes["error"] = json!("Too many application routes to display");
            continue;
        }
        match (target(graph, stream, direction), explicit(graph, stream)) {
            (Ok(Some(target)), Ok(pinned)) if endpoint_direction(target) == Some(direction) => {
                routes[direction.name()][&stream.serial] = json!({"target":target.serial, "mode": if pinned {"override"} else {"default"}});
            }
            (Err(_), _) | (_, Err(_)) => {
                routes["error"] = json!("Some application routes could not be read")
            }
            _ => (),
        }
    }
    routes
}
pub fn change(
    graph: &Graph,
    subject: u32,
    key: &str,
    value: Option<(&str, String)>,
) -> Result<Change> {
    Ok(Change {
        store: "default",
        id: *graph
            .metadata_ids
            .get("default")
            .ok_or_else(|| Failure::new("unavailable", "Audio routing metadata is unavailable"))?,
        subject,
        key: key.into(),
        before: metadata::subject_value(graph, "default", subject, key).cloned(),
        after: value.map(|(type_, value)| MetadataValue {
            subject,
            key: key.into(),
            type_: type_.into(),
            value,
        }),
    })
}
pub fn route_changes(
    graph: &Graph,
    stream: &Node,
    target: &Node,
    mode: Mode,
) -> Result<Vec<Change>> {
    explicit(graph, stream)?;
    [
        ("target.object", target.serial.clone()),
        ("target.node", target.id.to_string()),
    ]
    .into_iter()
    .map(|(key, value)| {
        change(
            graph,
            stream.id,
            key,
            Some((
                "Spa:Id",
                if mode == Mode::Default {
                    "-1".into()
                } else {
                    value
                },
            )),
        )
    })
    .collect()
}
pub async fn wait(native: &Handle, check: impl Fn(&Graph) -> Result<bool>) -> Result<()> {
    let mut state = native.subscribe();
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if check(&state.borrow_and_update())? {
                return Ok(());
            }
            state
                .changed()
                .await
                .map_err(|_| Failure::unknown("Audio disconnected during routing"))?;
        }
    })
    .await
    .map_err(|_| Failure::unknown("Audio routing change was not confirmed"))?
}
fn located(
    graph: &Graph,
    stream: &Identity,
    expected: Option<&Identity>,
    direction: Direction,
) -> Result<bool> {
    let node = native::validate_identity(graph, stream)?;
    if let Some(expected) = expected {
        endpoint(graph, expected, direction)?;
    }
    let actual = target(graph, node, direction)?;
    Ok(match (actual, expected) {
        (Some(node), Some(expected)) => node.id == expected.id && node.serial == expected.serial,
        (None, None) => true,
        _ => false,
    })
}
pub async fn set(native: &Handle, params: &Set) -> Result<()> {
    let graph = native.snapshot();
    let stream = native::validate_identity(&graph, &params.identity)?;
    let direction = stream_direction(stream)
        .ok_or_else(|| Failure::new("invalid_target", "Node is not an application audio stream"))?;
    let endpoint = endpoint(&graph, &params.target, direction)?;
    movable(&graph, stream)?;
    let previous = target(&graph, stream, direction)?.map(|n| identity(&graph, n));
    let mut changes = route_changes(&graph, stream, endpoint, params.mode)?;
    if params.mode == Mode::Default {
        if default_name(&graph, direction).as_deref() != Some(&endpoint.name) {
            return Err(Failure::new(
                "conflict",
                "The default audio device changed before routing began",
            ));
        }
        let mut guard = change(&graph, 0, direction.default_key(), None)?;
        guard.after = guard.before.clone();
        changes.push(guard);
    }
    let batch = Batch {
        generation: graph.generation.clone(),
        nodes: vec![params.identity.clone(), params.target.clone()],
        checks: vec![],
        changes,
    };
    let result = async {
        native.metadata(batch.clone()).await?;
        wait(native, |graph| {
            if !batch.confirmed(graph) {
                return Err(Failure::unknown(
                    "Application target changed during routing",
                ));
            }
            located(graph, &params.identity, Some(&params.target), direction)
        })
        .await
        .map_err(|e| Failure::unknown(e.message))
    }
    .await;
    if let Err(error) = result {
        if error.outcome != "unknown" && error.code != "stale_node" {
            return Err(error);
        }
        let graph = native.snapshot();
        // A third target belongs to another client. Metadata rollback must not
        // redirect that client's stream, even if our own values remain present.
        if let Ok(stream) = native::validate_identity(&graph, &params.identity) {
            if let Some(current) =
                target(&graph, stream, direction).map_err(|e| Failure::unknown(e.message))?
            {
                if current.id != params.target.id
                    && previous
                        .as_ref()
                        .is_none_or(|p| current.id != p.id || current.serial != p.serial)
                {
                    return Err(Failure::unknown(
                        "Another client rerouted the application; rollback was skipped",
                    ));
                }
            }
        }
        let rollback = batch
            .rollback(&graph)
            .map_err(|e| Failure::unknown(e.message))?;
        let restored = async {
            native.metadata(rollback.clone()).await?;
            wait(native, |graph| {
                if !graph.nodes.contains_key(&params.identity.id) {
                    return Ok(true);
                }
                Ok(rollback.confirmed(graph)
                    && located(graph, &params.identity, previous.as_ref(), direction)?)
            })
            .await
        }
        .await;
        return Err(if restored.is_ok() {
            Failure::new(
                "not_applied",
                "Application route was not applied; its previous state was restored",
            )
        } else {
            Failure::unknown("Application route could not be confirmed or restored")
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::native::Link;

    fn graph() -> Graph {
        let mut graph = Graph {
            connected: true,
            ready: true,
            generation: "test".into(),
            ..Graph::default()
        };
        for (id, name, class) in [
            (1, "app", "Stream/Output/Audio"),
            (2, "speakers", "Audio/Sink"),
            (3, "headphones", "Audio/Sink"),
        ] {
            graph.nodes.insert(
                id,
                Node {
                    id,
                    name: name.into(),
                    serial: (id + 100).to_string(),
                    properties: [("media.class".into(), class.into())].into(),
                    ..Node::default()
                },
            );
        }
        graph.metadata_ids.insert("default".into(), 10);
        graph.metadata.insert("default".into(), Default::default());
        graph.links.insert(
            20,
            Link {
                id: 20,
                output_node: 1,
                input_node: 2,
                state: "Paused".into(),
            },
        );
        graph
    }
    fn metadata(graph: &mut Graph, key: &str, value: &str) {
        graph.metadata.get_mut("default").unwrap().insert(
            format!("1:{key}"),
            MetadataValue {
                subject: 1,
                key: key.into(),
                value: value.into(),
                type_: "Spa:Id".into(),
            },
        );
    }
    #[test]
    fn route_snapshot_uses_links_and_keeps_a_pin_on_the_current_default() {
        let mut graph = graph();
        assert_eq!(
            snapshot(&graph)["playback"]["101"],
            json!({"target":"102", "mode":"default"})
        );
        graph
            .nodes
            .get_mut(&1)
            .unwrap()
            .properties
            .insert("target.object".into(), "speakers".into());
        assert_eq!(snapshot(&graph)["playback"]["101"]["mode"], "override");
        metadata(&mut graph, "target.object", "102");
        assert_eq!(snapshot(&graph)["playback"]["101"]["mode"], "override");
        metadata(&mut graph, "target.object", "-1");
        metadata(&mut graph, "target.node", "-1");
        assert_eq!(snapshot(&graph)["playback"]["101"]["mode"], "default");
        metadata(&mut graph, "target.object", "-2");
        assert!(explicit(&graph, &graph.nodes[&1]).is_err());
        assert_ne!(snapshot(&graph)["error"], "");
    }
    #[test]
    fn duplicate_channels_are_one_target_but_multiple_endpoints_are_ambiguous() {
        let mut graph = graph();
        graph.links.insert(
            21,
            Link {
                id: 21,
                ..graph.links[&20].clone()
            },
        );
        assert_eq!(
            target(&graph, &graph.nodes[&1], Direction::Playback)
                .unwrap()
                .unwrap()
                .id,
            2
        );
        graph.links.get_mut(&21).unwrap().input_node = 3;
        assert!(target(&graph, &graph.nodes[&1], Direction::Playback).is_err());
        assert!(snapshot(&graph)["playback"].as_object().unwrap().is_empty());
    }
    #[test]
    fn internal_streams_and_monitor_sources_are_not_manual_targets() {
        let mut graph = graph();
        graph
            .nodes
            .get_mut(&1)
            .unwrap()
            .properties
            .insert("pulse.module.id".into(), "42".into());
        assert!(stream_direction(&graph.nodes[&1]).is_none());
        assert!(snapshot(&graph)["playback"].as_object().unwrap().is_empty());
        let mut monitor = graph.nodes[&2].clone();
        monitor.name = "speakers.monitor".into();
        monitor
            .properties
            .insert("media.class".into(), "Audio/Source".into());
        assert!(endpoint_direction(&monitor).is_none());
        let mut group = graph.nodes[&2].clone();
        group.name = "omarchy_audio_group_0123456789abcdef".into();
        group
            .properties
            .insert("application.id".into(), "ssupt.audio-control".into());
        assert_eq!(endpoint_direction(&group), Some(Direction::Playback));
        group
            .properties
            .insert("media.class".into(), "Stream/Output/Audio".into());
        assert!(stream_direction(&group).is_none());
    }
}
