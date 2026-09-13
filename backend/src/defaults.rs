//! Default selection preserves explicit routes and the saved device preference.
use crate::files::{self, FileLock};
use crate::native::metadata::Batch;
use crate::native::{self, Graph, Handle, Identity};
use crate::protocol::{Failure, Result};
use crate::routing::{self, Direction, Mode};
use crate::storage::{Kind, Storage};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Set {
    pub identity: Identity,
    pub previous: Option<Identity>,
}

fn verify(
    graph: &Graph,
    batch: &Batch,
    expected: Option<&Identity>,
    expected_name: Option<&str>,
    followers: &[Identity],
    direction: Direction,
) -> Result<bool> {
    if let Some(expected) = expected {
        native::validate_identity(graph, expected)?;
    }
    if !batch.confirmed(graph)
        || routing::default_name(graph, direction).as_deref() != expected_name
    {
        return Ok(false);
    }
    for follower in followers {
        if !graph.nodes.contains_key(&follower.id) {
            continue;
        }
        let node = native::validate_identity(graph, follower)?;
        let current = routing::target(graph, node, direction)?;
        if current.is_none_or(|n| expected.is_none_or(|e| n.id != e.id || n.serial != e.serial)) {
            return Ok(false);
        }
    }
    Ok(true)
}

pub async fn select(native: &Handle, storage: Option<&Storage>, params: Set) -> Result<Value> {
    let storage = storage
        .ok_or_else(|| Failure::new("configuration_error", "Audio preferences are unavailable"))?
        .clone();
    let graph = native.snapshot();
    let node = native::validate_identity(&graph, &params.identity)?;
    let direction = routing::endpoint_direction(node)
        .ok_or_else(|| Failure::new("invalid_target", "Node is not an audio endpoint"))?;
    routing::endpoint(&graph, &params.identity, direction)?;
    // Share the directional preference lock with groups and the Bluetooth companion.
    let reader = storage.clone();
    let _preference_lock = tokio::task::spawn_blocking(move || {
        let path = reader.path(Kind::Preferences)?;
        std::fs::create_dir_all(path.parent().unwrap())?;
        let suffix = if direction == Direction::Playback {
            ".output.lock"
        } else {
            ".input.lock"
        };
        let lock = FileLock::acquire(&files::suffixed(&path, suffix))?;
        reader.read(Kind::Preferences)?;
        Ok::<_, Failure>(lock)
    })
    .await
    .map_err(|_| Failure::new("internal_error", "Could not read audio preferences"))??;
    let graph = native.snapshot();
    let node = routing::endpoint(&graph, &params.identity, direction)?;
    let name = node.name.clone();
    let previous_name = routing::default_name(&graph, direction);
    let mut old_nodes = graph
        .nodes
        .values()
        .filter(|n| Some(&n.name) == previous_name.as_ref());
    let previous = old_nodes.next().map(|n| routing::identity(&graph, n));
    if old_nodes.next().is_some() {
        return Err(Failure::new(
            "invalid_target",
            "The previous default is ambiguous",
        ));
    }
    if let Some(expected) = &params.previous {
        native::validate_identity(&graph, expected)?;
        if previous
            .as_ref()
            .is_none_or(|p| expected.id != p.id || expected.serial != p.serial)
        {
            return Err(Failure::new(
                "conflict",
                "The default audio device changed before selection began",
            ));
        }
    }
    let mut followers = Vec::new();
    let mut changes = Vec::new();
    if previous_name.as_deref() != Some(&name) {
        for stream in graph
            .nodes
            .values()
            .filter(|n| routing::stream_direction(n) == Some(direction))
        {
            if stream
                .properties
                .get("application.name")
                .is_some_and(|v| v == "EasyEffects")
            {
                continue;
            }
            if routing::explicit(&graph, stream)? {
                continue;
            }
            if routing::target(&graph, stream, direction)?
                .is_some_and(|n| previous.as_ref().is_some_and(|p| n.id == p.id))
            {
                routing::movable(&graph, stream)?;
                followers.push(routing::identity(&graph, stream));
                changes.extend(routing::route_changes(&graph, stream, node, Mode::Default)?);
            }
        }
        if followers.len() > 512 {
            return Err(Failure::new(
                "unsupported",
                "Too many applications to change the default safely",
            ));
        }
        changes.push(routing::change(
            &graph,
            0,
            direction.configured_key(),
            Some(("Spa:String:JSON", json!({"name":name}).to_string())),
        )?);
        let mut nodes = vec![params.identity.clone()];
        nodes.extend(previous.iter().cloned());
        nodes.extend(followers.iter().cloned());
        let batch = Batch {
            generation: graph.generation.clone(),
            changes,
            nodes,
            checks: vec![routing::change(&graph, 0, direction.default_key(), None)?],
        };
        let applied = async {
            native.metadata(batch.clone()).await?;
            routing::wait(native, |g| {
                verify(
                    g,
                    &batch,
                    Some(&params.identity),
                    Some(&name),
                    &followers,
                    direction,
                )
            })
            .await
            .map_err(|e| Failure::unknown(e.message))
        }
        .await;
        if let Err(error) = applied {
            if error.outcome != "unknown" {
                return Err(error);
            }
            let graph = native.snapshot();
            let current = routing::default_name(&graph, direction);
            if current.as_deref() != Some(&name) && current != previous_name {
                return Err(Failure::unknown(
                    "Another client selected an audio default; rollback was skipped",
                ));
            }
            for follower in &followers {
                if let Ok(stream) = native::validate_identity(&graph, follower) {
                    if let Some(target) = routing::target(&graph, stream, direction)
                        .map_err(|e| Failure::unknown(e.message))?
                    {
                        if previous
                            .as_ref()
                            .is_none_or(|p| target.id != p.id || target.serial != p.serial)
                            && target.id != params.identity.id
                        {
                            return Err(Failure::unknown(
                                "Another client rerouted an application; default rollback was skipped",
                            ));
                        }
                    }
                }
            }
            let rollback = batch
                .rollback(&graph)
                .map_err(|e| Failure::unknown(e.message))?;
            let restored = async {
                native.metadata(rollback.clone()).await?;
                routing::wait(native, |g| {
                    verify(
                        g,
                        &rollback,
                        previous.as_ref(),
                        previous_name.as_deref(),
                        &followers,
                        direction,
                    )
                })
                .await
            }
            .await;
            return Err(if restored.is_ok() {
                Failure::new(
                    "not_applied",
                    "Default device change was not applied; its previous state was restored",
                )
            } else {
                Failure::unknown("Default device change could not be confirmed or restored")
            });
        }
    }
    let writer = storage.clone();
    let saved = tokio::task::spawn_blocking(move || {
        writer.update(Kind::Preferences, |store| {
            store["defaults"][direction.preference()] = json!(name);
            Ok(())
        })
    })
    .await;
    if !matches!(saved, Ok(Ok(_))) {
        return Ok(
            json!({"outcome":"persistence_failed", "message":"Default device changed, but its preference could not be saved"}),
        );
    }
    Ok(json!({"outcome":"applied"}))
}
