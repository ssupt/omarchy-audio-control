//! Checked metadata writes on the existing PipeWire thread.
use super::{Completion, Graph, Handle, Message, MetadataValue, Proxies};
use crate::protocol::{Failure, Result};
use std::time::Duration;
use tokio::sync::oneshot;

#[derive(Clone)]
pub struct Change {
    pub store: &'static str,
    pub id: u32,
    pub key: String,
    pub before: Option<MetadataValue>,
    pub after: Option<MetadataValue>,
}

#[derive(Clone)]
pub struct Batch {
    pub generation: String,
    pub changes: Vec<Change>,
}

pub(super) struct Command {
    pub batch: Batch,
    pub completion: Completion,
}

pub fn value<'a>(graph: &'a Graph, store: &str, key: &str) -> Option<&'a MetadataValue> {
    graph.metadata.get(store)?.get(&format!("0:{key}"))
}

impl Batch {
    fn validate(&self, graph: &Graph) -> Result<()> {
        if !graph.ready
            || !graph.connected
            || graph.generation != self.generation
            || self
                .changes
                .iter()
                .any(|c| graph.metadata_ids.get(c.store) != Some(&c.id))
        {
            return Err(Failure::new(
                "stale_graph",
                "Audio settings changed; refresh before retrying",
            ));
        }
        Ok(())
    }

    pub(super) fn apply(&self, graph: &Graph, proxies: &Proxies) -> Result<()> {
        self.validate(graph)?;
        // Check every precondition before starting the batch. A companion's
        // newer value must not be overwritten by an operation waiting in the queue.
        for change in &self.changes {
            if value(graph, change.store, &change.key) != change.before.as_ref() {
                return Err(Failure::new(
                    "conflict",
                    "Audio setting changed before the operation started",
                ));
            }
            if !proxies.metadata.contains_key(&change.id) {
                return Err(Failure::new("stale_graph", "Audio settings disappeared"));
            }
        }
        for change in &self.changes {
            proxies.metadata[&change.id].metadata.set_property(
                0,
                &change.key,
                change.after.as_ref().map(|v| v.type_.as_str()),
                change.after.as_ref().map(|v| v.value.as_str()),
            );
        }
        Ok(())
    }

    pub fn confirmed(&self, graph: &Graph) -> bool {
        self.validate(graph).is_ok()
            && self
                .changes
                .iter()
                .all(|c| value(graph, c.store, &c.key) == c.after.as_ref())
    }

    pub fn rollback(&self, graph: &Graph) -> Result<Self> {
        self.validate(graph)?;
        let mut rollback = self.clone();
        for change in &mut rollback.changes {
            let current = value(graph, change.store, &change.key).cloned();
            if current != change.before && current != change.after {
                return Err(Failure::unknown(
                    "Another client changed the audio setting; rollback was skipped",
                ));
            }
            change.after = change.before.take();
            change.before = current;
        }
        Ok(rollback)
    }
}

impl Handle {
    pub async fn metadata(&self, batch: Batch) -> Result<()> {
        batch.validate(&self.snapshot())?;
        let permit = self
            .inner
            .permits
            .clone()
            .try_acquire_owned()
            .map_err(|_| Failure::new("busy", "Native command queue is full"))?;
        let sender = self
            .inner
            .sender
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| Failure::new("disconnected", "PipeWire is unavailable"))?;
        let (reply, receive) = oneshot::channel();
        let mut state = self.subscribe();
        sender
            .send(Message::Metadata(Command {
                batch: batch.clone(),
                completion: Completion {
                    reply,
                    _permit: permit,
                },
            }))
            .map_err(|_| Failure::new("disconnected", "PipeWire is unavailable"))?;
        tokio::time::timeout(Duration::from_secs(3), async {
            receive.await.map_err(|_| {
                Failure::unknown("PipeWire disconnected during the setting change")
            })??;
            loop {
                let graph = state.borrow_and_update().clone();
                batch.validate(&graph).map_err(|_| {
                    Failure::unknown("Audio settings disappeared during the change")
                })?;
                if batch.confirmed(&graph) {
                    return Ok(());
                }
                state.changed().await.map_err(|_| {
                    Failure::unknown("PipeWire disconnected during the setting change")
                })?;
            }
        })
        .await
        .map_err(|_| Failure::unknown("Audio setting change was not confirmed"))?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaced_metadata_and_concurrent_writes_are_not_rolled_back() {
        let before = MetadataValue {
            subject: 0,
            key: "test".into(),
            value: "false".into(),
            type_: "Spa:String:JSON".into(),
        };
        let after = MetadataValue {
            value: "true".into(),
            ..before.clone()
        };
        let mut graph = Graph {
            connected: true,
            ready: true,
            generation: "session".into(),
            ..Graph::default()
        };
        graph.metadata_ids.insert("sm-settings".into(), 10);
        graph
            .metadata
            .entry("sm-settings".into())
            .or_default()
            .insert("0:test".into(), after.clone());
        let batch = Batch {
            generation: "session".into(),
            changes: vec![Change {
                store: "sm-settings",
                id: 10,
                key: "test".into(),
                before: Some(before.clone()),
                after: Some(after),
            }],
        };
        assert!(batch.confirmed(&graph));
        assert_eq!(
            batch.rollback(&graph).unwrap().changes[0].after,
            Some(before)
        );
        graph
            .metadata
            .get_mut("sm-settings")
            .unwrap()
            .get_mut("0:test")
            .unwrap()
            .value = "external".into();
        assert!(batch.rollback(&graph).is_err());
        assert_eq!(
            batch.apply(&graph, &Proxies::default()).unwrap_err().code,
            "conflict"
        );
        graph.metadata_ids.insert("sm-settings".into(), 11);
        assert_eq!(batch.validate(&graph).unwrap_err().code, "stale_graph");
        assert!(!batch.confirmed(&graph));
    }
}
