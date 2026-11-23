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
    let has_app_automation = rules["appRules"]
        .as_array()
        .is_some_and(|items| !items.is_empty())
        || rules["pendingDefaultRoutes"]
            .as_array()
            .is_some_and(|items| !items.is_empty());
    let routes = if has_app_automation {
        crate::routing::snapshot(graph)
    } else {
        Value::Null
    };
    let defaults = if rules["pendingDefaultRoutes"]
        .as_array()
        .is_some_and(|pending| !pending.is_empty())
    {
        json!([
            crate::routing::default_name(graph, crate::routing::Direction::Playback),
            crate::routing::default_name(graph, crate::routing::Direction::Recording)
        ])
    } else {
        Value::Null
    };
    json!([
        graph.generation,
        graph.ready,
        topology,
        routes,
        rules["appRules"],
        rules["pendingDefaultRoutes"],
        defaults,
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
    // An orphan may still be the default or have applications linked to it.
    // Reconsider deferred removal when its use changes without replacing nodes.
    let default = crate::routing::default_name(graph, crate::routing::Direction::Playback);
    let usage: Vec<_> = graph
        .nodes
        .values()
        .filter(|n| storage::group_sink(&n.name))
        .map(|n| {
            let consumers: Vec<_> = graph
                .links
                .values()
                .filter(|l| l.input_node == n.id && matches!(l.state.as_str(), "Active" | "Paused"))
                .map(|l| l.output_node)
                .collect();
            json!([n.id, default.as_deref() == Some(&n.name), consumers])
        })
        .collect();
    json!([graph.generation, nodes, rules["outputGroups"], usage]).to_string()
}
pub struct PlannedRoute {
    pub key: String,
    pub set: crate::routing::Set,
    pub clear_pending: Option<(String, String)>,
}

pub fn routes(graph: &Graph, rules: &Value) -> Vec<PlannedRoute> {
    let mut result = Vec::new();
    for stream in graph.nodes.values().filter(|n| !n.serial.is_empty()) {
        let Some(direction) = crate::routing::stream_direction(stream) else {
            continue;
        };
        let app = app(stream);
        if let Some(rule) = rules["appRules"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|r| r["app"] == app && r["direction"] == direction.name())
        {
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
            if crate::routing::target(graph, stream, direction)
                .ok()
                .flatten()
                .is_some_and(|current| current.id == target.id && current.serial == target.serial)
                && crate::routing::explicit(graph, stream).unwrap_or(false)
            {
                continue;
            }
            let key = json!([
                graph.generation,
                stream.id,
                stream.serial,
                app,
                direction.name(),
                "override",
                target.id,
                target.serial,
                target.name
            ])
            .to_string();
            result.push(PlannedRoute {
                key,
                set: crate::routing::Set {
                    identity: crate::routing::identity(graph, stream),
                    target: crate::routing::identity(graph, target),
                    mode: crate::routing::Mode::Override,
                },
                clear_pending: None,
            });
            continue;
        }
        let pending = rules["pendingDefaultRoutes"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|entry| entry["app"] == app && entry["direction"] == direction.name());
        if !pending {
            continue;
        }
        let Some(default_name) = crate::routing::default_name(graph, direction) else {
            continue;
        };
        let mut targets = graph.nodes.values().filter(|n| {
            crate::routing::endpoint_direction(n) == Some(direction)
                && n.name == default_name
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
            "default",
            target.id,
            target.serial,
            target.name
        ])
        .to_string();
        result.push(PlannedRoute {
            key,
            set: crate::routing::Set {
                identity: crate::routing::identity(graph, stream),
                target: crate::routing::identity(graph, target),
                mode: crate::routing::Mode::Default,
            },
            clear_pending: Some((app, direction.name().into())),
        });
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::native::MetadataValue;
    use std::collections::BTreeMap;

    #[test]
    fn pending_default_routes_plan_follow_default_when_app_appears() {
        let mut graph = Graph {
            connected: true,
            ready: true,
            generation: "test".into(),
            ..Graph::default()
        };
        graph.nodes.insert(
            1,
            Node {
                id: 1,
                serial: "101".into(),
                name: "output_a".into(),
                state: "Idle".into(),
                properties: BTreeMap::from([("media.class".into(), "Audio/Sink".into())]),
                ..Node::default()
            },
        );
        graph.nodes.insert(
            2,
            Node {
                id: 2,
                serial: "102".into(),
                name: "player".into(),
                state: "Running".into(),
                properties: BTreeMap::from([
                    ("media.class".into(), "Stream/Output/Audio".into()),
                    ("application.name".into(), "Player".into()),
                ]),
                ..Node::default()
            },
        );
        graph.metadata.insert(
            "default".into(),
            BTreeMap::from([(
                "0:default.audio.sink".into(),
                MetadataValue {
                    subject: 0,
                    key: "default.audio.sink".into(),
                    type_: "Spa:String:JSON".into(),
                    value: json!({"name": "output_a"}).to_string(),
                },
            )]),
        );
        let rules = json!({
            "appRules": [],
            "pendingDefaultRoutes": [{"app": "player", "direction": "playback"}]
        });
        let planned = routes(&graph, &rules);
        assert_eq!(planned.len(), 1);
        assert_eq!(planned[0].set.mode, crate::routing::Mode::Default);
        assert_eq!(planned[0].set.target.id, 1);
        assert_eq!(
            planned[0].clear_pending,
            Some(("player".into(), "playback".into()))
        );
    }
}
