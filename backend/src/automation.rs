//! Event-driven rule and output-group reconciliation. A UI subscription is a
//! lease: disabling the plugin prevents new automatic changes.
use crate::native::{Graph, Node};
use crate::storage;
use serde_json::{Value, json};

fn class(node: &Node) -> &str {
    node.properties
        .get("media.class")
        .map(String::as_str)
        .unwrap_or("")
}
pub fn app(node: &Node) -> String {
    let label = [
        "application.name",
        "node.description",
        "media.name",
        "node.name",
    ]
    .iter()
    .find_map(|key| node.properties.get(*key).filter(|v| !v.is_empty()))
    .unwrap_or(&node.name);
    storage::label(&json!(label), 120).to_ascii_lowercase()
}
pub fn signature(graph: &Graph, rules: &Value) -> String {
    let topology: Vec<_> = graph
        .nodes
        .values()
        .filter(|n| class(n).starts_with("Audio/") || class(n).starts_with("Stream/"))
        .map(|n| {
            json!([
                n.id,
                n.serial,
                n.name,
                class(n),
                app(n),
                !n.state.is_empty()
            ])
        })
        .collect();
    json!([
        graph.generation,
        graph.ready,
        topology,
        rules["appRules"],
        rules["outputGroups"]
    ])
    .to_string()
}
pub fn group_signature(graph: &Graph, rules: &Value) -> String {
    let nodes: Vec<_> = graph
        .nodes
        .values()
        .filter(|n| {
            class(n) == "Audio/Sink"
                || (class(n) == "Stream/Output/Audio"
                    && n.name.starts_with("output.omarchy_audio_group_"))
        })
        .map(|n| json!([n.id, n.serial, n.name, !n.state.is_empty()]))
        .collect();
    json!([graph.generation, nodes, rules["outputGroups"]]).to_string()
}
pub fn routes(graph: &Graph, rules: &Value) -> Vec<(String, crate::routing::Set)> {
    let mut result = Vec::new();
    for stream in graph.nodes.values().filter(|n| !n.serial.is_empty()) {
        let Some(direction) = crate::routing::stream_direction(stream) else {
            continue;
        };
        let app = app(stream);
        let Some(rule) = rules["appRules"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|r| r["app"] == app && r["direction"] == direction.name())
        else {
            continue;
        };
        let mut targets = graph.nodes.values().filter(|n| {
            crate::routing::endpoint_direction(n) == Some(direction)
                && rule["target"] == n.name
                && !n.serial.is_empty()
        });
        let Some(target) = targets.next() else {
            continue;
        };
        if targets.next().is_some() {
            continue;
        }
        let key = json!([
            graph.generation,
            stream.id,
            stream.serial,
            app,
            direction.name(),
            target.id,
            target.serial,
            target.name
        ])
        .to_string();
        result.push((
            key,
            crate::routing::Set {
                identity: crate::routing::identity(graph, stream),
                target: crate::routing::identity(graph, target),
                mode: crate::routing::Mode::Override,
            },
        ));
    }
    result
}
