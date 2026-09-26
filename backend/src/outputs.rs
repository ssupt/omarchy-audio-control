//! Output visibility and DSP volume targets from the existing native graph.
use crate::{
    native::{self, Graph, Node},
    routing, storage,
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

const TUNING: &str = "omarchy_speaker_tuning";

fn sink(node: &Node) -> bool {
    routing::class(node) == "Audio/Sink"
        && !node.state.is_empty()
        && !node.name.is_empty()
        && !node.serial.is_empty()
        && storage::identifier(&json!(node.name), 160) == node.name
}

fn renderers<'a>(graph: &'a Graph, output: &Node) -> Vec<&'a Node> {
    graph
        .nodes
        .values()
        .filter(|n| {
            if routing::class(n) != "Stream/Output/Audio" || n.state.is_empty() {
                return false;
            }
            let paired = n
                .name
                .strip_prefix(&output.name)
                .is_some_and(|suffix| suffix.starts_with(['_', '-', '.']))
                || output
                    .properties
                    .get("node.link-group")
                    .is_some_and(|group| {
                        !group.is_empty() && n.properties.get("node.link-group") == Some(group)
                    });
            let same_client = match (
                output.properties.get("client.id"),
                n.properties.get("client.id"),
            ) {
                (Some(a), Some(b)) => a == b,
                _ => true,
            };
            same_client
                && (paired
                    || (output.name == "easyeffects_sink"
                        && n.properties
                            .get("application.name")
                            .is_some_and(|v| v == "EasyEffects")))
        })
        .collect()
}

struct View<'a> {
    graph: &'a Graph,
    sinks: BTreeMap<&'a str, &'a Node>,
    forward: BTreeMap<u32, BTreeSet<u32>>,
}
impl<'a> View<'a> {
    fn target(&self, value: &str) -> Option<&'a Node> {
        let mut matches = self
            .sinks
            .values()
            .copied()
            .filter(|n| n.name == value || n.serial == value);
        let node = matches.next()?;
        matches.next().is_none().then_some(node)
    }
    fn volume(&self, output: &'a Node) -> &'a Node {
        // A combined output owns its gain. Never replace it with one member.
        if output.name.starts_with("alsa_output.")
            || storage::group_sink(&output.name)
            || output.properties.contains_key("device.id")
            || output
                .properties
                .get("node.virtual")
                .is_some_and(|v| matches!(v.as_str(), "false" | "0"))
        {
            return output;
        }
        let mut targets = BTreeSet::new();
        for renderer in renderers(self.graph, output) {
            for id in self.forward.get(&renderer.id).into_iter().flatten() {
                if self
                    .graph
                    .nodes
                    .get(id)
                    .is_some_and(|n| self.sinks.contains_key(n.name.as_str()))
                {
                    targets.insert(*id);
                }
            }
        }
        // EasyEffects also links native filter nodes directly (no Pulse stream).
        if output.name == "easyeffects_sink"
            && !self.walk_effects(output.id, &mut BTreeSet::new(), &mut targets, &mut 128)
        {
            return output;
        }
        if targets.len() != 1 {
            return output;
        }
        self.graph
            .nodes
            .get(targets.first().unwrap())
            .unwrap_or(output)
    }
    fn walk_effects(
        &self,
        id: u32,
        visited: &mut BTreeSet<u32>,
        targets: &mut BTreeSet<u32>,
        budget: &mut usize,
    ) -> bool {
        if *budget == 0 || !visited.insert(id) {
            return false;
        }
        *budget -= 1;
        for next in self.forward.get(&id).into_iter().flatten() {
            let Some(node) = self.graph.nodes.get(next) else {
                return false;
            };
            if self.sinks.contains_key(node.name.as_str()) {
                targets.insert(*next);
            } else if node
                .properties
                .get("application.id")
                .is_some_and(|v| v == "com.github.wwmm.easyeffects")
                && !self.walk_effects(*next, visited, targets, budget)
            {
                return false;
            }
        }
        visited.remove(&id);
        true
    }
}

pub fn snapshot(graph: &Graph) -> Value {
    if !graph.ready || !graph.connected || graph.nodes.len() > 4096 || graph.links.len() > 8192 {
        return json!({"availability":{}, "volume":null});
    }
    let mut names = BTreeMap::<&str, usize>::new();
    for node in graph.nodes.values() {
        *names.entry(&node.name).or_default() += 1;
    }
    let sinks: BTreeMap<_, _> = graph
        .nodes
        .values()
        .filter(|n| sink(n) && names[n.name.as_str()] == 1)
        .take(512)
        .map(|n| (n.name.as_str(), n))
        .collect();
    let mut forward = BTreeMap::<u32, BTreeSet<u32>>::new();
    for link in graph
        .links
        .values()
        .filter(|l| matches!(l.state.as_str(), "Active" | "Paused"))
    {
        forward
            .entry(link.output_node)
            .or_default()
            .insert(link.input_node);
    }
    let view = View {
        graph,
        sinks,
        forward,
    };
    let mut availability: BTreeMap<&str, bool> = graph
        .nodes
        .values()
        .filter(|n| sink(n))
        .take(512)
        .map(|n| {
            (
                n.name.as_str(),
                names[n.name.as_str()] == 1 && native::catalog::output_available(graph, n),
            )
        })
        .collect();
    if let Some(tuning) = view.sinks.get(TUNING) {
        // The pinned target remains meaningful while the tuning is idle/unlinked.
        let renderers = renderers(graph, tuning);
        let declared = if renderers.len() == 1 {
            renderers[0]
                .properties
                .get("target.object")
                .and_then(|v| view.target(v))
        } else {
            None
        };
        let fronted = declared.unwrap_or_else(|| view.volume(tuning));
        if fronted.id != tuning.id {
            availability.insert(&fronted.name, false);
        }
    }
    let selected = routing::default_name(graph, routing::Direction::Playback)
        .and_then(|name| view.sinks.get(name.as_str()).copied());
    let volume = selected.map(|source| {
        json!({"source":routing::identity(graph, source),
        "target":routing::identity(graph, view.volume(source))})
    });
    json!({"availability":availability, "volume":volume})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::native::{Link, MetadataValue};

    fn add(graph: &mut Graph, id: u32, name: &str, class: &str) {
        graph.nodes.insert(
            id,
            Node {
                id,
                serial: (id + 100).to_string(),
                name: name.into(),
                state: "Running".into(),
                properties: BTreeMap::from([
                    ("media.class".into(), class.into()),
                    ("client.id".into(), "1".into()),
                ]),
                ..Node::default()
            },
        );
    }
    fn select(graph: &mut Graph, name: &str) {
        graph.metadata.entry("default".into()).or_default().insert(
            "0:default.audio.sink".into(),
            MetadataValue {
                subject: 0,
                key: "default.audio.sink".into(),
                type_: "Spa:String:JSON".into(),
                value: json!({"name":name}).to_string(),
            },
        );
    }
    fn link(graph: &mut Graph, from: u32, to: u32) {
        let id = graph.links.len() as u32;
        graph.links.insert(
            id,
            Link {
                id,
                output_node: from,
                input_node: to,
                state: "Paused".into(),
            },
        );
    }
    fn graph() -> Graph {
        let mut graph = Graph {
            ready: true,
            connected: true,
            generation: "test".into(),
            ..Graph::default()
        };
        add(&mut graph, 1, "alsa_output.speakers", "Audio/Sink");
        add(&mut graph, 2, "headphones", "Audio/Sink");
        add(&mut graph, 3, TUNING, "Audio/Sink");
        add(
            &mut graph,
            4,
            "omarchy_speaker_tuning_output",
            "Stream/Output/Audio",
        );
        graph
            .nodes
            .get_mut(&4)
            .unwrap()
            .properties
            .insert("target.object".into(), "alsa_output.speakers".into());
        select(&mut graph, TUNING);
        graph
    }
    #[test]
    fn idle_tuning_hides_its_pinned_output_but_volume_follows_live_links_and_default() {
        let mut g = graph();
        assert_eq!(snapshot(&g)["availability"]["alsa_output.speakers"], false);
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 3);
        link(&mut g, 4, 1);
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 1);
        select(&mut g, "headphones");
        assert_eq!(snapshot(&g)["volume"]["source"]["id"], 2);
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 2);
        g.nodes.remove(&3);
        assert_eq!(snapshot(&g)["availability"]["alsa_output.speakers"], true);
    }
    #[test]
    fn groups_ambiguous_targets_and_foreign_renderers_keep_their_own_gain() {
        let mut g = graph();
        link(&mut g, 4, 1);
        link(&mut g, 4, 2);
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 3);
        g.links.remove(&1);
        g.nodes
            .get_mut(&4)
            .unwrap()
            .properties
            .insert("client.id".into(), "2".into());
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 3);
        let name = "omarchy_audio_group_0123456789abcdef";
        add(&mut g, 5, name, "Audio/Sink");
        add(&mut g, 6, &format!("{name}_output"), "Stream/Output/Audio");
        link(&mut g, 6, 1);
        select(&mut g, name);
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 5);
    }
    #[test]
    fn replacement_duplicate_names_and_disconnect_invalidate_old_targets() {
        let mut g = graph();
        link(&mut g, 4, 1);
        g.nodes.get_mut(&1).unwrap().serial = "new-serial".into();
        assert_eq!(snapshot(&g)["volume"]["target"]["serial"], "new-serial");
        add(&mut g, 5, "alsa_output.speakers", "Audio/Sink");
        assert_eq!(snapshot(&g)["availability"]["alsa_output.speakers"], false);
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 3);
        g.connected = false;
        assert_eq!(snapshot(&g), json!({"availability":{},"volume":null}));
    }
    #[test]
    fn easyeffects_native_filter_links_are_bounded_and_reject_cycles() {
        let mut g = graph();
        add(&mut g, 5, "easyeffects_sink", "Audio/Sink");
        select(&mut g, "easyeffects_sink");
        for id in 6..10 {
            add(&mut g, id, &format!("ee_{id}"), "Audio/Filter");
            g.nodes.get_mut(&id).unwrap().properties.insert(
                "application.id".into(),
                "com.github.wwmm.easyeffects".into(),
            );
            link(&mut g, id - 1, id);
        }
        link(&mut g, 9, 1);
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 1);
        link(&mut g, 9, 6);
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 5);
        g.links.clear();
        // A graph with many reconverging paths must not grow exponential work.
        for from in 5..9 {
            for to in from + 1..10 {
                link(&mut g, from, to);
            }
        }
        link(&mut g, 9, 1);
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 1);
        g.links.values_mut().for_each(|l| l.state = "Error".into());
        assert_eq!(snapshot(&g)["volume"]["target"]["id"], 5);
    }
}
