use crate::{native::Graph, storage};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

pub(super) fn routes(graph: &Graph) -> Vec<Value> {
    let mut forward = BTreeMap::<u32, BTreeSet<u32>>::new();
    let mut reverse = forward.clone();
    for link in graph
        .links
        .values()
        .take(8192)
        .filter(|l| matches!(l.state.as_str(), "Active" | "Paused"))
    {
        for (map, from, to) in [
            (&mut forward, link.output_node, link.input_node),
            (&mut reverse, link.input_node, link.output_node),
        ] {
            let neighbours = map.entry(from).or_default();
            if neighbours.len() < 16 {
                neighbours.insert(to);
            }
        }
    }
    let mut routes = BTreeMap::new();
    for (class, direction, adjacency) in [
        ("Stream/Output/Audio", "playback", forward),
        ("Stream/Input/Audio", "recording", reverse),
    ] {
        for node in graph
            .nodes
            .values()
            .take(4096)
            .filter(|n| {
                n.properties.get("media.class").is_some_and(|v| v == class)
                    && n.properties
                        .get("application.id")
                        .is_none_or(|v| v != "ssupt.audio-control")
            })
            .take(64)
        {
            let mut paths = Vec::new();
            walk(node.id, &adjacency, &mut Vec::new(), &mut paths);
            for path in paths.into_iter().filter(|p| p.len() > 1) {
                let labels: Vec<_> = path
                    .iter()
                    .map(|id| {
                        let Some(node) = graph.nodes.get(id) else {
                            return "Unavailable audio node".into();
                        };
                        let stream = node
                            .properties
                            .get("media.class")
                            .is_some_and(|v| v.starts_with("Stream/"));
                        let keys: &[&str] = if stream {
                            &["application.name"]
                        } else {
                            &["node.description", "node.nick"]
                        };
                        let label = keys
                            .iter()
                            .find_map(|key| node.properties.get(*key))
                            .map(String::as_str)
                            .filter(|label| {
                                stream || node.name.is_empty() || !label.contains(&node.name)
                            })
                            .unwrap_or(if stream {
                                "Audio application"
                            } else {
                                "Audio node"
                            });
                        storage::label(&json!(label), 160)
                    })
                    .collect();
                routes.insert(
                    (direction, labels.clone()),
                    json!({"direction":direction, "labels":labels}),
                );
                if routes.len() >= 64 {
                    return routes.into_values().collect();
                }
            }
        }
    }
    routes.into_values().collect()
}

fn walk(
    id: u32,
    adjacency: &BTreeMap<u32, BTreeSet<u32>>,
    path: &mut Vec<u32>,
    paths: &mut Vec<Vec<u32>>,
) {
    if paths.len() >= 8 {
        return;
    }
    let stop = path.contains(&id) || path.len() >= 15;
    path.push(id);
    if stop || adjacency.get(&id).is_none_or(BTreeSet::is_empty) {
        paths.push(path.clone());
    } else {
        for next in &adjacency[&id] {
            walk(*next, adjacency, path, paths);
            if paths.len() >= 8 {
                break;
            }
        }
    }
    path.pop();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dense_cycles_have_bounded_paths() {
        let adjacency = (0..32).map(|i| (i, (0..32).collect())).collect();
        let mut paths = Vec::new();
        walk(0, &adjacency, &mut Vec::new(), &mut paths);
        assert_eq!(paths.len(), 8);
        assert!(paths.iter().all(|p| p.len() <= 16));
    }
}
