//! Port selection and rollback on the existing PipeWire connection.
use super::{Completion, Graph, Handle, Identity, Message, Proxies, catalog, validate_identity};
use crate::protocol::{Failure, Result};
use pipewire::spa;
use std::{io::Cursor, time::Duration};
use tokio::sync::oneshot;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Port {
    index: i32,
    name: String,
}
impl Port {
    fn matches(&self, port: &catalog::Port) -> bool {
        self.index == port.index && self.name == port.name
    }
}
impl From<&catalog::Port> for Port {
    fn from(port: &catalog::Port) -> Self {
        Self {
            index: port.index,
            name: port.name.clone(),
        }
    }
}

#[derive(Clone)]
pub(super) struct Change {
    identity: Identity,
    device_id: u32,
    device_serial: String,
    profile_device: i32,
    profile: Option<i32>,
    observed: u64,
    before: Port,
    after: Port,
}

pub(super) struct Command {
    pub change: Change,
    pub completion: Completion,
}

fn endpoint<'a>(graph: &'a Graph, identity: &Identity) -> Result<catalog::Endpoint<'a>> {
    let node = validate_identity(graph, identity)?;
    let endpoint = catalog::endpoint(graph, node)
        .ok_or_else(|| Failure::new("unavailable", "Audio ports are unavailable or ambiguous"))?;
    if !endpoint.device.catalog_ready || endpoint.device.param_request.is_some() {
        return Err(Failure::new("busy", "Audio ports are updating"));
    }
    if !endpoint.device.route_writable {
        return Err(Failure::new(
            "unsupported",
            "This device does not allow port changes",
        ));
    }
    Ok(endpoint)
}

impl Change {
    fn new(graph: &Graph, identity: Identity, port: &str) -> Result<Self> {
        if port.is_empty() || crate::storage::identifier(&serde_json::json!(port), 160) != port {
            return Err(Failure::new("invalid_params", "Invalid audio port"));
        }
        let endpoint = endpoint(graph, &identity)?;
        let before = endpoint
            .active
            .ok_or_else(|| Failure::new("unsupported", "The current audio port is unknown"))?;
        let after = endpoint
            .choices
            .iter()
            .find(|p| p.name == port)
            .ok_or_else(|| Failure::new("unavailable", "That audio port is no longer available"))?;
        let device_serial = endpoint
            .device
            .properties
            .get("object.serial")
            .filter(|s| !s.is_empty())
            .ok_or_else(|| Failure::new("unsupported", "Audio device identity is unavailable"))?;
        Ok(Self {
            identity,
            device_id: endpoint.device.id,
            device_serial: device_serial.clone(),
            profile_device: endpoint.profile_device,
            profile: endpoint.device.catalog.profile(),
            observed: endpoint.device.route_revision,
            before: before.into(),
            after: (*after).into(),
        })
    }

    fn inspect<'a>(&self, graph: &'a Graph) -> Result<catalog::Endpoint<'a>> {
        let endpoint = endpoint(graph, &self.identity)?;
        if endpoint.device.id != self.device_id
            || endpoint.device.properties.get("object.serial") != Some(&self.device_serial)
            || endpoint.profile_device != self.profile_device
            || endpoint.device.catalog.profile() != self.profile
        {
            return Err(Failure::new(
                "stale_node",
                "Audio device or profile changed during port selection",
            ));
        }
        Ok(endpoint)
    }

    pub(super) fn apply(&self, graph: &Graph, proxies: &Proxies) -> Result<()> {
        let endpoint = self.inspect(graph)?;
        if endpoint.device.route_revision != self.observed
            || !endpoint.active.is_some_and(|p| self.before.matches(p))
        {
            return Err(Failure::new(
                "conflict",
                "Audio port changed before the operation started",
            ));
        }
        if !endpoint.choices.iter().any(|p| self.after.matches(p)) {
            return Err(Failure::new(
                "unavailable",
                "That audio port is no longer available",
            ));
        }
        let device = proxies
            .devices
            .get(&self.device_id)
            .ok_or_else(|| Failure::new("stale_node", "Audio device disappeared"))?;
        let data = self.pod()?;
        let pod = spa::pod::Pod::from_bytes(&data)
            .ok_or_else(|| Failure::new("encoding_error", "Invalid audio port parameters"))?;
        device
            .device
            .set_param(spa::param::ParamType::Route, 0, pod);
        Ok(())
    }

    fn pod(&self) -> Result<Vec<u8>> {
        use spa::pod::{Object, Property, Value};
        // Like PipeWire-Pulse's set_card_port, omit Props so the device/session
        // manager can restore the destination port's own volume and mute state.
        let value = Value::Object(Object {
            type_: spa::sys::SPA_TYPE_OBJECT_ParamRoute,
            id: spa::sys::SPA_PARAM_Route,
            properties: vec![
                Property::new(
                    spa::sys::SPA_PARAM_ROUTE_index,
                    Value::Int(self.after.index),
                ),
                Property::new(
                    spa::sys::SPA_PARAM_ROUTE_device,
                    Value::Int(self.profile_device),
                ),
                Property::new(spa::sys::SPA_PARAM_ROUTE_save, Value::Bool(true)),
            ],
        });
        spa::pod::serialize::PodSerializer::serialize(Cursor::new(Vec::new()), &value)
            .map(|(output, _)| output.into_inner())
            .map_err(|_| Failure::new("encoding_error", "Could not encode audio port parameters"))
    }

    fn confirmed(&self, graph: &Graph) -> Result<bool> {
        let endpoint = self.inspect(graph)?;
        Ok(endpoint.device.route_revision != self.observed
            && endpoint.active.is_some_and(|p| self.after.matches(p)))
    }

    fn rollback(&self, graph: &Graph) -> Result<Self> {
        let endpoint = self.inspect(graph)?;
        let current = endpoint.active.map(Port::from);
        if current.as_ref() != Some(&self.before) && current.as_ref() != Some(&self.after) {
            return Err(Failure::unknown(
                "Another client changed the audio port; rollback was skipped",
            ));
        }
        if !endpoint.choices.iter().any(|p| self.before.matches(p)) {
            return Err(Failure::unknown(
                "The previous audio port is no longer available",
            ));
        }
        Ok(Self {
            before: current.unwrap(),
            after: self.before.clone(),
            observed: endpoint.device.route_revision,
            ..self.clone()
        })
    }
}

impl Handle {
    /// Caller owns the service transaction and companion-compatible mutation lock.
    pub async fn select_port(&self, identity: Identity, port: &str) -> Result<()> {
        let change = Change::new(&self.snapshot(), identity, port)?;
        if change.before == change.after {
            return Ok(());
        }
        if let Err(error) = self.port_change(change.clone()).await {
            if error.outcome != "unknown" {
                return Err(error);
            }
            let rollback = change.rollback(&self.snapshot()).map_err(|_| {
                Failure::unknown("Audio port could not be confirmed; its previous port cannot be safely restored")
            })?;
            self.port_change(rollback)
                .await
                .map_err(|_| Failure::unknown("Audio port could not be confirmed or restored"))?;
            return Err(Failure::new(
                "not_applied",
                "Audio port change was not confirmed; its previous port was restored",
            ));
        }
        Ok(())
    }

    async fn port_change(&self, change: Change) -> Result<()> {
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
            .send(Message::Port(Command {
                change: change.clone(),
                completion: Completion {
                    reply,
                    _permit: permit,
                },
            }))
            .map_err(|_| Failure::new("disconnected", "PipeWire is unavailable"))?;
        tokio::time::timeout(Duration::from_secs(3), async {
            receive
                .await
                .map_err(|_| Failure::unknown("PipeWire disconnected during port selection"))??;
            loop {
                let graph = state.borrow_and_update().clone();
                match change.confirmed(&graph) {
                    Ok(true) => return Ok(()),
                    Ok(false) => (),
                    Err(error) if error.code == "busy" => (),
                    Err(_) => {
                        return Err(Failure::unknown(
                            "Audio device or port changed during selection",
                        ));
                    }
                }
                state
                    .changed()
                    .await
                    .map_err(|_| Failure::unknown("PipeWire disconnected during port selection"))?;
            }
        })
        .await
        .map_err(|_| Failure::unknown("Audio port change was not confirmed"))?
    }
}

#[cfg(test)]
mod tests {
    use super::super::{Device, Node};
    use super::*;
    use spa::pod::{Object, Property, Value, ValueArray};
    use std::{collections::BTreeMap, sync::Arc};

    fn active(graph: &mut Graph, index: i32) {
        let device = graph.devices.get_mut(&10).unwrap();
        Arc::make_mut(&mut device.catalog).read(
            spa::sys::SPA_PARAM_Route,
            0,
            &Object {
                type_: spa::sys::SPA_TYPE_OBJECT_ParamRoute,
                id: spa::sys::SPA_PARAM_Route,
                properties: vec![
                    Property::new(spa::sys::SPA_PARAM_ROUTE_index, Value::Int(index)),
                    Property::new(spa::sys::SPA_PARAM_ROUTE_device, Value::Int(4)),
                ],
            },
        );
        device.route_revision += 1;
    }

    fn fixture() -> (Graph, Identity) {
        let mut catalog = catalog::Catalog::default();
        for index in 0..3 {
            catalog.read(
                spa::sys::SPA_PARAM_EnumRoute,
                index,
                &Object {
                    type_: spa::sys::SPA_TYPE_OBJECT_ParamRoute,
                    id: spa::sys::SPA_PARAM_EnumRoute,
                    properties: vec![
                        Property::new(spa::sys::SPA_PARAM_ROUTE_index, Value::Int(index as i32)),
                        Property::new(
                            spa::sys::SPA_PARAM_ROUTE_name,
                            Value::String(format!("port{index}")),
                        ),
                        Property::new(
                            spa::sys::SPA_PARAM_ROUTE_direction,
                            Value::Id(spa::utils::Id(spa::sys::SPA_DIRECTION_OUTPUT)),
                        ),
                        Property::new(
                            spa::sys::SPA_PARAM_ROUTE_devices,
                            Value::ValueArray(ValueArray::Int(vec![4])),
                        ),
                    ],
                },
            );
        }
        let identity = Identity {
            generation: "session".into(),
            id: 20,
            serial: "200".into(),
        };
        let mut graph = Graph {
            generation: identity.generation.clone(),
            connected: true,
            ready: true,
            devices: [(
                10,
                Device {
                    id: 10,
                    properties: [("object.serial".into(), "100".into())].into(),
                    catalog: Arc::new(catalog),
                    catalog_ready: true,
                    route_writable: true,
                    ..Device::default()
                },
            )]
            .into(),
            nodes: [(
                20,
                Node {
                    id: 20,
                    serial: identity.serial.clone(),
                    name: "speaker".into(),
                    properties: BTreeMap::from([
                        ("media.class".into(), "Audio/Sink".into()),
                        ("device.id".into(), "10".into()),
                        ("card.profile.device".into(), "4".into()),
                    ]),
                    ..Node::default()
                },
            )]
            .into(),
            ..Graph::default()
        };
        active(&mut graph, 0);
        (graph, identity)
    }

    #[test]
    fn rollback_requires_fresh_state_and_preserves_other_clients() {
        let (mut graph, identity) = fixture();
        let change = Change::new(&graph, identity, "port1").unwrap();
        assert!(!change.confirmed(&graph).unwrap());
        let rollback = change.rollback(&graph).unwrap();
        assert!(
            !rollback.confirmed(&graph).unwrap(),
            "Cached original port is not rollback confirmation"
        );
        active(&mut graph, 0);
        assert!(rollback.confirmed(&graph).unwrap());
        active(&mut graph, 1);
        assert!(change.confirmed(&graph).unwrap());
        assert_eq!(change.rollback(&graph).unwrap().after.name, "port0");
        active(&mut graph, 2);
        assert!(change.rollback(&graph).is_err());
        assert_eq!(
            change.apply(&graph, &Proxies::default()).unwrap_err().code,
            "conflict"
        );
        graph
            .devices
            .get_mut(&10)
            .unwrap()
            .properties
            .insert("object.serial".into(), "replacement".into());
        assert!(change.rollback(&graph).is_err());
        assert!(change.confirmed(&graph).is_err());
    }

    #[test]
    fn port_changes_reject_read_only_pending_and_monitor_devices() {
        let (mut graph, identity) = fixture();
        assert!(graph.nodes[&20].audio.volumes.is_empty());
        assert_eq!(
            catalog::port_identity(&graph, "output", "speaker")
                .unwrap()
                .serial,
            identity.serial
        );
        assert!(catalog::port_identity(&graph, "input", "speaker").is_none());
        graph.devices.get_mut(&10).unwrap().route_writable = false;
        assert_eq!(
            Change::new(&graph, identity.clone(), "port1")
                .err()
                .unwrap()
                .code,
            "unsupported"
        );
        graph.devices.get_mut(&10).unwrap().route_writable = true;
        graph.devices.get_mut(&10).unwrap().param_request = Some(1);
        assert_eq!(
            Change::new(&graph, identity.clone(), "port1")
                .err()
                .unwrap()
                .code,
            "busy"
        );
        graph.devices.get_mut(&10).unwrap().param_request = None;
        graph.nodes.get_mut(&20).unwrap().properties.extend([
            ("media.class".into(), "Audio/Source".into()),
            ("device.class".into(), "monitor".into()),
        ]);
        assert_eq!(
            Change::new(&graph, identity, "port1").err().unwrap().code,
            "unavailable"
        );
    }
}
