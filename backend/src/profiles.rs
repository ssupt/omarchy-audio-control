//! Profile transitions preserve endpoint levels and the mute state of live streams.
//! The caller retains the service transaction and companion mutation lock.
use crate::native::profiles::{Guard, Selection};
use crate::native::{self, AudioPatch, Graph, Handle, Identity, Node};
use crate::protocol::{Failure, Result};
use crate::storage::{Kind, Storage};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[derive(Clone)]
struct Saved {
    identity: Identity,
    node: Node,
}
fn saved(graph: &Graph, node: &Node) -> Result<Saved> {
    if node.serial.is_empty() || node.audio.muted.is_none() {
        return Err(Failure::new("busy", "Audio endpoint state is updating"));
    }
    if node.audio.volumes.len() > 64
        || node
            .audio
            .volumes
            .iter()
            .any(|v| !v.is_finite() || !(0.0..=1.5).contains(v))
    {
        return Err(Failure::new(
            "unsupported",
            "Audio state cannot be safely restored",
        ));
    }
    Ok(Saved {
        identity: Identity {
            generation: graph.generation.clone(),
            id: node.id,
            serial: node.serial.clone(),
        },
        node: node.clone(),
    })
}
fn class(node: &Node) -> &str {
    node.properties
        .get("media.class")
        .map(String::as_str)
        .unwrap_or("")
}
fn endpoints(graph: &Graph, guard: &Guard) -> Result<Vec<Saved>> {
    guard.inspect(graph)?;
    let nodes: Vec<_> = graph
        .nodes
        .values()
        .filter(|n| {
            n.properties.get("device.id").and_then(|v| v.parse().ok()) == Some(guard.identity.id)
                && matches!(class(n), "Audio/Sink" | "Audio/Source")
        })
        .collect();
    if nodes.len() > 64
        || nodes
            .iter()
            .any(|n| n.name.is_empty() || nodes.iter().filter(|m| m.name == n.name).count() != 1)
    {
        return Err(Failure::new(
            "unsupported",
            "Audio endpoints are ambiguous or too numerous",
        ));
    }
    nodes.into_iter().map(|n| saved(graph, n)).collect()
}
fn streams(graph: &Graph, endpoints: &[Saved]) -> Result<Vec<Saved>> {
    let streams: Vec<_> = graph
        .nodes
        .values()
        .filter(|n| {
            class(n) == "Stream/Output/Audio"
                && graph.links.values().any(|link| {
                    link.output_node == n.id
                        && endpoints
                            .iter()
                            .any(|e| class(&e.node) == "Audio/Sink" && e.node.id == link.input_node)
                })
        })
        .collect();
    if streams.len() > 64 {
        return Err(Failure::new(
            "unsupported",
            "Too many streams for a profile transition",
        ));
    }
    streams.into_iter().map(|n| saved(graph, n)).collect()
}
fn counts_ready(nodes: &[Saved], guard: &Guard) -> bool {
    [
        ("Audio/Sink", guard.profile.sinks),
        ("Audio/Source", guard.profile.sources),
    ]
    .into_iter()
    .all(|(class_name, expected)| {
        let count = nodes
            .iter()
            .filter(|n| class(&n.node) == class_name)
            .count();
        if expected == 0 {
            count == 0
        } else {
            count >= expected as usize
        }
    })
}
fn restore_patch(old: &[Saved], new: &Saved, index: usize) -> AudioPatch {
    let same_direction: Vec<_> = old
        .iter()
        .filter(|n| class(&n.node) == class(&new.node))
        .collect();
    let source = same_direction
        .iter()
        .find(|n| n.node.name == new.node.name)
        .copied()
        .or_else(|| same_direction.get(index).copied());
    let source = source.unwrap_or(new);
    let volumes = if source.node.audio.volumes.is_empty() || new.node.audio.volumes.is_empty() {
        None
    } else if source.node.audio.volumes.len() == new.node.audio.volumes.len() {
        Some(source.node.audio.volumes.clone())
    } else {
        Some(vec![
            source.node.audio.volumes[0];
            new.node.audio.volumes.len()
        ])
    };
    AudioPatch {
        muted: source.node.audio.muted,
        volumes,
    }
}
struct Transition<'a> {
    native: &'a Handle,
    deadline: Instant,
}
impl<'a> Transition<'a> {
    fn new(native: &'a Handle) -> Self {
        Self {
            native,
            deadline: Instant::now() + Duration::from_secs(40),
        }
    }
    async fn patch(&self, node: &Saved, patch: AudioPatch, guard: Option<&Guard>) -> Result<()> {
        if Instant::now() >= self.deadline {
            return Err(Failure::unknown(
                "Audio profile restoration deadline reached",
            ));
        }
        self.native
            .patch_guarded(node.identity.clone(), patch, guard.cloned())
            .await
    }
    async fn mute(&self, nodes: &[Saved], guard: &Guard) -> Result<()> {
        for node in nodes {
            self.patch(
                node,
                AudioPatch {
                    muted: Some(true),
                    volumes: None,
                },
                Some(guard),
            )
            .await?;
        }
        let graph = self.native.snapshot();
        guard.inspect(&graph)?;
        for node in nodes {
            if native::validate_identity(&graph, &node.identity)?
                .audio
                .muted
                != Some(true)
            {
                return Err(Failure::unknown(
                    "Audio could not be muted before changing the profile",
                ));
            }
        }
        Ok(())
    }
    async fn restore_mutes(&self, nodes: &[Saved]) -> bool {
        let mut complete = true;
        for node in nodes {
            // A vanished object needs no cleanup. A replacement must not inherit its mute state.
            let graph = self.native.snapshot();
            match native::validate_identity(&graph, &node.identity) {
                Ok(live) if live.audio.muted == node.node.audio.muted => continue,
                Ok(_) => (),
                Err(error) if error.code == "stale_node" => continue,
                Err(_) => {
                    complete = false;
                    continue;
                }
            }
            if self
                .patch(
                    node,
                    AudioPatch {
                        muted: node.node.audio.muted,
                        volumes: None,
                    },
                    None,
                )
                .await
                .is_err()
            {
                complete = false;
            }
        }
        complete
    }
    async fn settle(&self, guard: &Guard) -> Result<Vec<Saved>> {
        let mut state = self.native.subscribe();
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let graph = state.borrow_and_update().clone();
                match endpoints(&graph, guard) {
                    Ok(nodes) if counts_ready(&nodes, guard) => return Ok(nodes),
                    Ok(_) => (),
                    Err(e) if e.code == "busy" => (),
                    Err(e) => return Err(e),
                }
                state.changed().await.map_err(|_| {
                    Failure::unknown("Audio disconnected while waiting for endpoints")
                })?;
            }
        })
        .await
        .map_err(|_| Failure::unknown("Audio endpoints did not settle after the profile change"))?
    }
    async fn restore(&self, old: &[Saved], new: &[Saved], guard: &Guard) -> Result<()> {
        self.mute(new, guard).await?;
        let mut patches = vec![];
        for direction in ["Audio/Sink", "Audio/Source"] {
            for (index, node) in new
                .iter()
                .filter(|n| class(&n.node) == direction)
                .enumerate()
            {
                let patch = restore_patch(old, node, index);
                if patch.volumes.is_some() {
                    self.patch(
                        node,
                        AudioPatch {
                            muted: Some(true),
                            volumes: patch.volumes.clone(),
                        },
                        Some(guard),
                    )
                    .await?;
                }
                patches.push((node, patch));
            }
        }
        // Every endpoint's level is restored before any endpoint is unmuted.
        for (node, patch) in &patches {
            self.patch(
                node,
                AudioPatch {
                    muted: patch.muted,
                    volumes: None,
                },
                Some(guard),
            )
            .await?;
        }
        let graph = self.native.snapshot();
        guard.inspect(&graph)?;
        for (node, patch) in patches {
            native::verify_patch(&graph, &node.identity, &patch)?;
        }
        Ok(())
    }
    async fn rollback(&self, selection: &Selection, old: &[Saved]) -> Result<()> {
        let graph = self.native.snapshot();
        let current = if selection.after.inspect(&graph).is_ok() {
            &selection.after
        } else if selection.before.inspect(&graph).is_ok() {
            &selection.before
        } else {
            return Err(Failure::unknown(
                "Audio device or profile changed externally; rollback was skipped",
            ));
        };
        let nodes = endpoints(&graph, current)?;
        self.mute(&nodes, current).await?;
        // Reissue even if the cached profile is the original: a silent write may have landed.
        self.native
            .switch_profile(
                current.clone(),
                selection.before.clone(),
                nodes.iter().map(|n| n.identity.clone()).collect(),
            )
            .await?;
        let restored = self.settle(&selection.before).await?;
        self.restore(old, &restored, &selection.before).await
    }
}

pub async fn select(
    native: &Handle,
    storage: Option<&Storage>,
    identity: Identity,
    profile: &str,
) -> Result<Value> {
    let selection = Selection::new(&native.snapshot(), identity, profile)?;
    if selection.address.is_some() {
        let storage = storage
            .cloned()
            .ok_or_else(|| Failure::new("unavailable", "Audio preferences are unavailable"))?;
        tokio::task::spawn_blocking(move || storage.read(Kind::Preferences))
            .await
            .map_err(|_| Failure::new("internal_error", "Could not read audio preferences"))??;
    }
    if selection.before.profile.index != selection.after.profile.index {
        let graph = native.snapshot();
        let old = endpoints(&graph, &selection.before)?;
        let streams = streams(&graph, &old)?;
        let transition = Transition::new(native);
        let prepare = async {
            transition.mute(&old, &selection.before).await?;
            transition.mute(&streams, &selection.before).await
        }
        .await;
        if let Err(error) = prepare {
            let cleanup = Transition::new(native);
            let endpoints_ok = cleanup.restore_mutes(&old).await;
            let streams_ok = cleanup.restore_mutes(&streams).await;
            return Err(if endpoints_ok && streams_ok {
                Failure::new("not_applied", format!("Profile unchanged: {error}"))
            } else {
                Failure::unknown(
                    "Profile preparation failed and mute state could not be fully restored",
                )
            });
        }
        let prepared = old
            .iter()
            .chain(&streams)
            .map(|n| n.identity.clone())
            .collect();
        let switch = native
            .switch_profile(selection.before.clone(), selection.after.clone(), prepared)
            .await;
        let changed = switch.is_ok();
        let result = async {
            switch?;
            let new = transition.settle(&selection.after).await?;
            transition.restore(&old, &new, &selection.after).await
        }
        .await;
        if let Err(error) = result {
            let cleanup = Transition::new(native);
            let recovery = if changed || error.outcome == "unknown" {
                cleanup.rollback(&selection, &old).await.is_ok()
            } else {
                cleanup.restore_mutes(&old).await
            };
            let streams_ok = cleanup.restore_mutes(&streams).await;
            return Err(if recovery && streams_ok {
                Failure::new(
                    "not_applied",
                    format!("{error}; the previous audio state was restored"),
                )
            } else {
                Failure::unknown(
                    "Profile change failed and the previous audio state could not be fully restored",
                )
            });
        }
        if !transition.restore_mutes(&streams).await {
            return Err(Failure::unknown(
                "Audio profile changed, but stream mute state could not be fully restored",
            ));
        }
    }
    selection
        .after
        .inspect(&native.snapshot())
        .map_err(|_| Failure::unknown("Audio profile changed during restoration"))?;
    if let Some(address) = selection.address {
        let storage = storage.unwrap().clone();
        let profile = selection.after.profile.name;
        let saved = tokio::task::spawn_blocking(move || {
            storage.update(Kind::Preferences, |store| {
                store["bluetoothProfiles"][address] = json!(profile);
                Ok(())
            })
        })
        .await;
        if !matches!(saved, Ok(Ok(_))) {
            return Ok(
                json!({"outcome":"persistence_failed","message":"Audio profile changed, but its preference could not be saved"}),
            );
        }
    }
    Ok(json!({"outcome":"applied"}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::native::Audio;
    use std::collections::BTreeMap;
    fn node(name: &str, direction: &str, volumes: &[f64], muted: bool) -> Saved {
        saved(
            &Graph {
                generation: "test".into(),
                ..Graph::default()
            },
            &Node {
                id: 1,
                serial: "1".into(),
                name: name.into(),
                audio: Audio {
                    volumes: volumes.into(),
                    muted: Some(muted),
                    ..Audio::default()
                },
                properties: BTreeMap::from([("media.class".into(), direction.into())]),
                ..Node::default()
            },
        )
        .unwrap()
    }
    #[test]
    fn restore_matches_names_before_order_and_preserves_direction_and_channels() {
        let old = vec![
            node("speaker", "Audio/Sink", &[0.2, 0.3], false),
            node("mic-a", "Audio/Source", &[0.4], false),
            node("mic-b", "Audio/Source", &[0.7], true),
        ];
        let new = node("mic-b", "Audio/Source", &[1., 1.], false);
        let patch = restore_patch(&old, &new, 0);
        assert_eq!(patch.volumes, Some(vec![0.7, 0.7]));
        assert_eq!(patch.muted, Some(true));
        let renamed = node("headphones", "Audio/Sink", &[1.], true);
        let patch = restore_patch(&old, &renamed, 0);
        assert_eq!(patch.volumes, Some(vec![0.2]));
        assert_eq!(patch.muted, Some(false));
        let extra = node("mic-c", "Audio/Source", &[0.6], true);
        let patch = restore_patch(&old, &extra, 2);
        assert_eq!(patch.volumes, Some(vec![0.6]));
        assert_eq!(patch.muted, Some(true));
    }
}
