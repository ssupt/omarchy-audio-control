//! Profile writes use the existing device proxy and wait for fresh SPA state.
use super::{
    Completion, Device, Graph, Handle, Identity, Message, Proxies, catalog, validate_identity,
};
use crate::protocol::{Failure, Result};
use pipewire::spa;
use std::{io::Cursor, time::Duration};
use tokio::sync::oneshot;

#[derive(Clone, Debug)]
pub(crate) struct Guard {
    pub identity: Identity,
    pub profile: catalog::Profile,
}

pub(crate) fn device<'a>(graph: &'a Graph, identity: &Identity) -> Result<&'a Device> {
    if !graph.ready || !graph.connected || graph.generation != identity.generation {
        return Err(Failure::new(
            "stale_graph",
            "Audio graph changed; refresh before retrying",
        ));
    }
    let device = graph
        .devices
        .get(&identity.id)
        .filter(|d| {
            !identity.serial.is_empty()
                && d.properties.get("object.serial") == Some(&identity.serial)
        })
        .ok_or_else(|| Failure::new("stale_device", "Audio device disappeared or was replaced"))?;
    if !device.catalog_ready || device.param_request.is_some() {
        return Err(Failure::new("busy", "Audio profiles are updating"));
    }
    Ok(device)
}
impl Guard {
    pub fn inspect<'a>(&self, graph: &'a Graph) -> Result<&'a Device> {
        let device = device(graph, &self.identity)?;
        let card = catalog::card(graph, device).ok_or_else(|| {
            Failure::new("unavailable", "Audio profiles are unavailable or ambiguous")
        })?;
        if !card
            .active
            .is_some_and(|p| p.index == self.profile.index && p.name == self.profile.name)
        {
            return Err(Failure::new(
                "conflict",
                "Another client changed the audio profile",
            ));
        }
        Ok(device)
    }
}

pub(crate) struct Selection {
    pub before: Guard,
    pub after: Guard,
    pub address: Option<String>,
}
impl Selection {
    pub fn new(graph: &Graph, identity: Identity, profile: &str) -> Result<Self> {
        if profile.is_empty()
            || crate::storage::identifier(&serde_json::json!(profile), 160) != profile
        {
            return Err(Failure::new("invalid_params", "Invalid audio profile"));
        }
        let device = device(graph, &identity)?;
        if !device.profile_writable {
            return Err(Failure::new(
                "unsupported",
                "This device does not allow profile changes",
            ));
        }
        let card = catalog::card(graph, device).ok_or_else(|| {
            Failure::new("unavailable", "Audio profiles are unavailable or ambiguous")
        })?;
        let before = card
            .active
            .ok_or_else(|| Failure::new("unsupported", "The current audio profile is unknown"))?;
        let after = card
            .choices
            .iter()
            .find(|p| p.name == profile)
            .ok_or_else(|| {
                Failure::new("unavailable", "That audio profile is no longer available")
            })?;
        let address = if card.bluetooth {
            let raw = device
                .properties
                .get("api.bluez5.address")
                .or_else(|| device.properties.get("device.string"));
            let address: String = raw
                .into_iter()
                .flat_map(|s| s.chars())
                .filter(char::is_ascii_hexdigit)
                .map(|c| c.to_ascii_lowercase())
                .collect();
            if address.len() != 12 {
                return Err(Failure::new(
                    "unavailable",
                    "Bluetooth device address is unavailable",
                ));
            }
            Some(address)
        } else {
            None
        };
        Ok(Self {
            before: Guard {
                identity: identity.clone(),
                profile: before.clone(),
            },
            after: Guard {
                identity,
                profile: (*after).clone(),
            },
            address,
        })
    }
}

#[derive(Clone)]
pub(super) struct Change {
    before: Guard,
    after: Guard,
    observed: u64,
    prepared: Vec<Identity>,
}
pub(super) struct Command {
    pub change: Change,
    pub completion: Completion,
}
impl Change {
    pub(super) fn apply(&self, graph: &Graph, proxies: &Proxies) -> Result<()> {
        let device = self.before.inspect(graph)?;
        if !device.profile_writable || device.profile_revision != self.observed {
            return Err(Failure::new(
                "conflict",
                "Audio profile changed before the operation started",
            ));
        }
        let card = catalog::card(graph, device).unwrap();
        if !card
            .choices
            .iter()
            .any(|p| p.index == self.after.profile.index && p.name == self.after.profile.name)
        {
            return Err(Failure::new(
                "unavailable",
                "That audio profile is no longer available",
            ));
        }
        for identity in &self.prepared {
            let node = validate_identity(graph, identity)?;
            let audio = super::audio::route_for(graph, node)
                .map(|(_, route)| &route.audio)
                .unwrap_or(&node.audio);
            if audio.muted != Some(true) {
                return Err(Failure::new(
                    "conflict",
                    "Audio changed during profile preparation",
                ));
            }
        }
        if graph.nodes.values().any(|n| {
            n.properties.get("device.id").and_then(|v| v.parse().ok()) == Some(device.id)
                && matches!(
                    n.properties.get("media.class").map(String::as_str),
                    Some("Audio/Sink" | "Audio/Source")
                )
                && !self
                    .prepared
                    .iter()
                    .any(|id| id.id == n.id && id.serial == n.serial)
        }) {
            return Err(Failure::new(
                "conflict",
                "Audio endpoints changed during profile preparation",
            ));
        }
        let proxy = proxies
            .devices
            .get(&device.id)
            .ok_or_else(|| Failure::new("stale_device", "Audio device disappeared"))?;
        let data = profile_pod(self.after.profile.index)?;
        let pod = spa::pod::Pod::from_bytes(&data)
            .ok_or_else(|| Failure::new("encoding_error", "Invalid audio profile parameters"))?;
        proxy
            .device
            .set_param(spa::param::ParamType::Profile, 0, pod);
        Ok(())
    }
}
fn profile_pod(index: i32) -> Result<Vec<u8>> {
    use spa::pod::{Object, Property, Value};
    let value = Value::Object(Object {
        type_: spa::sys::SPA_TYPE_OBJECT_ParamProfile,
        id: spa::sys::SPA_PARAM_Profile,
        properties: vec![
            Property::new(spa::sys::SPA_PARAM_PROFILE_index, Value::Int(index)),
            Property::new(spa::sys::SPA_PARAM_PROFILE_save, Value::Bool(true)),
        ],
    });
    spa::pod::serialize::PodSerializer::serialize(Cursor::new(Vec::new()), &value)
        .map(|(output, _)| output.into_inner())
        .map_err(|_| {
            Failure::new(
                "encoding_error",
                "Could not encode audio profile parameters",
            )
        })
}
impl Handle {
    /// The caller retains the transaction/lock and restores endpoints and streams.
    pub(crate) async fn switch_profile(
        &self,
        before: Guard,
        after: Guard,
        prepared: Vec<Identity>,
    ) -> Result<()> {
        let observed = before.inspect(&self.snapshot())?.profile_revision;
        let change = Change {
            before,
            after,
            observed,
            prepared,
        };
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
            .send(Message::Profile(Command {
                change: change.clone(),
                completion: Completion {
                    reply,
                    _permit: permit,
                },
            }))
            .map_err(|_| Failure::new("disconnected", "PipeWire is unavailable"))?;
        tokio::time::timeout(Duration::from_secs(3), async {
            receive.await.map_err(|_| {
                Failure::unknown("PipeWire disconnected during profile selection")
            })??;
            loop {
                let graph = state.borrow_and_update().clone();
                match device(&graph, &change.after.identity) {
                    Ok(device) => {
                        if device.profile_revision != observed
                            && change.after.inspect(&graph).is_ok()
                        {
                            return Ok(());
                        }
                        if device.profile_revision != observed
                            && change.before.inspect(&graph).is_err()
                        {
                            return Err(Failure::unknown(
                                "Another client changed the audio profile",
                            ));
                        }
                    }
                    Err(e) if e.code == "busy" => (),
                    Err(_) => {
                        return Err(Failure::unknown(
                            "Audio device changed during profile selection",
                        ));
                    }
                }
                state.changed().await.map_err(|_| {
                    Failure::unknown("PipeWire disconnected during profile selection")
                })?;
            }
        })
        .await
        .map_err(|_| Failure::unknown("Audio profile change was not confirmed"))?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use spa::pod::{Object, Property, Value};
    use std::{collections::BTreeMap, sync::Arc};

    fn graph() -> (Graph, Identity) {
        let identity = Identity {
            generation: "test".into(),
            id: 7,
            serial: "70".into(),
        };
        let mut catalog = catalog::Catalog::default();
        for (index, name) in [(0, "off"), (1, "HiFi"), (2, "headset")] {
            catalog.read(
                spa::sys::SPA_PARAM_EnumProfile,
                index as u32,
                &Object {
                    type_: spa::sys::SPA_TYPE_OBJECT_ParamProfile,
                    id: spa::sys::SPA_PARAM_EnumProfile,
                    properties: vec![
                        Property::new(spa::sys::SPA_PARAM_PROFILE_index, Value::Int(index)),
                        Property::new(spa::sys::SPA_PARAM_PROFILE_name, Value::String(name.into())),
                    ],
                },
            );
        }
        catalog.read(
            spa::sys::SPA_PARAM_Profile,
            0,
            &Object {
                type_: spa::sys::SPA_TYPE_OBJECT_ParamProfile,
                id: spa::sys::SPA_PARAM_Profile,
                properties: vec![Property::new(
                    spa::sys::SPA_PARAM_PROFILE_index,
                    Value::Int(1),
                )],
            },
        );
        (
            Graph {
                generation: "test".into(),
                connected: true,
                ready: true,
                devices: BTreeMap::from([(
                    7,
                    Device {
                        id: 7,
                        catalog_ready: true,
                        profile_writable: true,
                        catalog: Arc::new(catalog),
                        properties: BTreeMap::from([
                            ("device.name".into(), "test-card".into()),
                            ("object.serial".into(), "70".into()),
                            ("device.api".into(), "bluez5".into()),
                            ("api.bluez5.address".into(), "AA:BB:CC:DD:EE:FF".into()),
                        ]),
                        ..Device::default()
                    },
                )]),
                ..Graph::default()
            },
            identity,
        )
    }
    #[test]
    fn profile_selection_requires_live_unambiguous_writable_identity() {
        let (mut graph, identity) = graph();
        let selection = Selection::new(&graph, identity.clone(), "headset").unwrap();
        assert_eq!(selection.address.as_deref(), Some("aabbccddeeff"));
        assert_eq!(selection.before.profile.name, "HiFi");
        assert_eq!(selection.after.profile.index, 2);
        for profile in ["", "bad\nprofile", "unknown"] {
            assert!(Selection::new(&graph, identity.clone(), profile).is_err());
        }
        let mut stale = identity.clone();
        stale.serial = "71".into();
        assert!(Selection::new(&graph, stale, "headset").is_err());
        graph.generation = "reconnected".into();
        assert!(Selection::new(&graph, identity.clone(), "headset").is_err());
        graph.generation = identity.generation.clone();
        graph.devices.get_mut(&7).unwrap().profile_writable = false;
        assert!(Selection::new(&graph, identity.clone(), "headset").is_err());
        graph.devices.get_mut(&7).unwrap().profile_writable = true;
        let mut duplicate = graph.devices[&7].clone();
        duplicate.id = 8;
        graph.devices.insert(8, duplicate);
        assert!(Selection::new(&graph, identity, "headset").is_err());
    }
    #[test]
    fn profile_guard_rejects_external_changes_and_incomplete_catalogs() {
        let (mut graph, identity) = graph();
        let selection = Selection::new(&graph, identity, "headset").unwrap();
        assert!(selection.before.inspect(&graph).is_ok());
        assert!(selection.after.inspect(&graph).is_err());
        graph.devices.get_mut(&7).unwrap().catalog_ready = false;
        assert_eq!(selection.before.inspect(&graph).unwrap_err().code, "busy");
        graph.devices.get_mut(&7).unwrap().catalog_ready = true;
        Arc::make_mut(&mut graph.devices.get_mut(&7).unwrap().catalog)
            .clear(spa::sys::SPA_PARAM_Profile);
        assert!(selection.before.inspect(&graph).is_err());
    }
    #[test]
    fn profile_request_saves_only_the_profile_index() {
        let bytes = profile_pod(2).unwrap();
        let (_, Value::Object(object)) =
            spa::pod::deserialize::PodDeserializer::deserialize_any_from(&bytes).unwrap()
        else {
            panic!()
        };
        assert_eq!(object.type_, spa::sys::SPA_TYPE_OBJECT_ParamProfile);
        assert_eq!(object.id, spa::sys::SPA_PARAM_Profile);
        assert_eq!(object.properties.len(), 2);
        assert!(
            object
                .properties
                .iter()
                .any(|p| p.key == spa::sys::SPA_PARAM_PROFILE_index && p.value == Value::Int(2))
        );
        assert!(
            object
                .properties
                .iter()
                .any(|p| p.key == spa::sys::SPA_PARAM_PROFILE_save && p.value == Value::Bool(true))
        );
    }
}
