//! Device profiles and endpoint ports derived from SPA parameters.
use super::{Device, Graph, Identity, Node};
use crate::storage::{identifier, label};
use pipewire::spa::{
    self,
    pod::{Object, Value, ValueArray},
};
use serde_json::{Value as Json, json};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct Catalog {
    profiles: BTreeMap<u32, Profile>,
    active_profile: BTreeMap<u32, i32>,
    ports: BTreeMap<u32, Port>,
    active_routes: BTreeMap<u32, (i32, i32)>,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Profile {
    pub index: i32,
    pub name: String,
    label: String,
    priority: i32,
    available: bool,
    pub sinks: i32,
    pub sources: i32,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Port {
    pub index: i32,
    pub name: String,
    label: String,
    direction: u32,
    priority: i32,
    available: bool,
    profiles: Vec<i32>,
    devices: Vec<i32>,
}

fn field(object: &Object, key: u32) -> Option<&Value> {
    let mut matches = object.properties.iter().filter(|p| p.key == key);
    let value = &matches.next()?.value;
    matches.next().is_none().then_some(value)
}
fn integer(object: &Object, key: u32) -> Option<i32> {
    match field(object, key)? {
        Value::Int(v) if *v >= 0 => Some(*v),
        _ => None,
    }
}
fn text(object: &Object, key: u32) -> String {
    match field(object, key) {
        Some(Value::String(v)) => v.clone(),
        _ => String::new(),
    }
}
fn name(object: &Object, key: u32) -> String {
    identifier(&json!(text(object, key)), 160)
}
fn description(object: &Object, key: u32, fallback: &str) -> String {
    let value = label(&json!(text(object, key)), 160);
    if value.is_empty() {
        fallback.into()
    } else {
        value
    }
}
fn indexes(object: &Object, key: u32) -> Vec<i32> {
    match field(object, key) {
        Some(Value::ValueArray(ValueArray::Int(values)))
            if values.len() <= 256 && values.iter().all(|v| *v >= 0) =>
        {
            values.clone()
        }
        _ => vec![],
    }
}
fn available(object: &Object, key: u32) -> bool {
    !matches!(field(object,key), Some(Value::Id(v)) if v.0 == spa::sys::SPA_PARAM_AVAILABILITY_no)
}
pub(super) fn object(pod: &spa::pod::Pod) -> Option<Object> {
    if pod.as_bytes().len() > 65536 {
        return None;
    }
    match spa::pod::deserialize::PodDeserializer::deserialize_any_from(pod.as_bytes())
        .ok()?
        .1
    {
        Value::Object(object) => Some(object),
        _ => None,
    }
}

impl Catalog {
    pub(super) fn profile(&self) -> Option<i32> {
        self.active_profile.values().next().copied()
    }

    pub fn clear(&mut self, param: u32) {
        match param {
            spa::sys::SPA_PARAM_EnumProfile => self.profiles.clear(),
            spa::sys::SPA_PARAM_Profile => self.active_profile.clear(),
            spa::sys::SPA_PARAM_EnumRoute => self.ports.clear(),
            spa::sys::SPA_PARAM_Route => self.active_routes.clear(),
            _ => (),
        }
    }
    pub fn differs(&self, other: &Self, param: u32) -> bool {
        match param {
            spa::sys::SPA_PARAM_EnumProfile => self.profiles != other.profiles,
            spa::sys::SPA_PARAM_Profile => self.active_profile != other.active_profile,
            spa::sys::SPA_PARAM_EnumRoute => self.ports != other.ports,
            spa::sys::SPA_PARAM_Route => self.active_routes != other.active_routes,
            _ => false,
        }
    }
    pub fn take(&mut self, other: &mut Self, param: u32) {
        match param {
            spa::sys::SPA_PARAM_EnumProfile => self.profiles = std::mem::take(&mut other.profiles),
            spa::sys::SPA_PARAM_Profile => {
                self.active_profile = std::mem::take(&mut other.active_profile)
            }
            spa::sys::SPA_PARAM_EnumRoute => self.ports = std::mem::take(&mut other.ports),
            spa::sys::SPA_PARAM_Route => {
                self.active_routes = std::mem::take(&mut other.active_routes)
            }
            _ => (),
        }
    }
    pub fn read(&mut self, param: u32, index: u32, object: &Object) {
        let expected = match param {
            spa::sys::SPA_PARAM_Profile | spa::sys::SPA_PARAM_EnumProfile => {
                spa::sys::SPA_TYPE_OBJECT_ParamProfile
            }
            spa::sys::SPA_PARAM_Route | spa::sys::SPA_PARAM_EnumRoute => {
                spa::sys::SPA_TYPE_OBJECT_ParamRoute
            }
            _ => return,
        };
        if index >= 256 || object.type_ != expected || object.id != param {
            return;
        }
        match param {
            spa::sys::SPA_PARAM_Profile => {
                if let Some(value) = integer(object, spa::sys::SPA_PARAM_PROFILE_index) {
                    self.active_profile.insert(index, value);
                }
            }
            spa::sys::SPA_PARAM_Route => {
                if let Some(pair) = integer(object, spa::sys::SPA_PARAM_ROUTE_index)
                    .zip(integer(object, spa::sys::SPA_PARAM_ROUTE_device))
                {
                    self.active_routes.insert(index, pair);
                }
            }
            spa::sys::SPA_PARAM_EnumProfile => {
                let Some(id) = integer(object, spa::sys::SPA_PARAM_PROFILE_index) else {
                    return;
                };
                let name = name(object, spa::sys::SPA_PARAM_PROFILE_name);
                if name.is_empty() {
                    return;
                }
                let mut profile = Profile {
                    index: id,
                    label: description(object, spa::sys::SPA_PARAM_PROFILE_description, &name),
                    name,
                    priority: integer(object, spa::sys::SPA_PARAM_PROFILE_priority)
                        .filter(|p| *p <= 1_000_000_000)
                        .unwrap_or(0),
                    available: available(object, spa::sys::SPA_PARAM_PROFILE_available),
                    sinks: 0,
                    sources: 0,
                };
                if let Some(Value::Struct(classes)) =
                    field(object, spa::sys::SPA_PARAM_PROFILE_classes)
                {
                    for class in classes.iter().skip(1).take(64) {
                        if let Value::Struct(values) = class {
                            if let [Value::String(name), Value::Int(count), ..] = values.as_slice()
                            {
                                let count = if (0..=64).contains(count) { *count } else { 0 };
                                match name.as_str() {
                                    "Audio/Sink" => profile.sinks = count,
                                    "Audio/Source" => profile.sources = count,
                                    _ => (),
                                }
                            }
                        }
                    }
                }
                self.profiles.insert(index, profile);
            }
            spa::sys::SPA_PARAM_EnumRoute => {
                let Some(id) = integer(object, spa::sys::SPA_PARAM_ROUTE_index) else {
                    return;
                };
                let name = name(object, spa::sys::SPA_PARAM_ROUTE_name);
                let Some(Value::Id(direction)) = field(object, spa::sys::SPA_PARAM_ROUTE_direction)
                else {
                    return;
                };
                if name.is_empty() || direction.0 > 1 {
                    return;
                }
                self.ports.insert(
                    index,
                    Port {
                        index: id,
                        label: description(object, spa::sys::SPA_PARAM_ROUTE_description, &name),
                        name,
                        direction: direction.0,
                        priority: integer(object, spa::sys::SPA_PARAM_ROUTE_priority)
                            .filter(|p| *p <= 1_000_000_000)
                            .unwrap_or(0),
                        available: available(object, spa::sys::SPA_PARAM_ROUTE_available),
                        profiles: indexes(object, spa::sys::SPA_PARAM_ROUTE_profiles),
                        devices: indexes(object, spa::sys::SPA_PARAM_ROUTE_devices),
                    },
                );
            }
            _ => (),
        }
    }
}

pub fn ready(graph: &Graph) -> bool {
    graph.ready && graph.devices.values().all(|d| d.catalog_ready)
}

pub(super) struct Endpoint<'a> {
    pub device: &'a Device,
    pub profile_device: i32,
    pub direction: &'static str,
    pub active: Option<&'a Port>,
    pub choices: Vec<&'a Port>,
}

pub(super) fn endpoint<'a>(graph: &'a Graph, node: &Node) -> Option<Endpoint<'a>> {
    let device = graph
        .devices
        .get(&node.properties.get("device.id")?.parse::<u32>().ok()?)?;
    let catalog = &device.catalog;
    if catalog.active_profile.len() > 1 {
        return None;
    }
    let direction = match node.properties.get("media.class").map(String::as_str) {
        Some("Audio/Sink") => "output",
        Some("Audio/Source")
            if !node.name.ends_with(".monitor")
                && node
                    .properties
                    .get("device.class")
                    .is_none_or(|v| !v.eq_ignore_ascii_case("monitor")) =>
        {
            "input"
        }
        _ => return None,
    };
    if identifier(&json!(node.name), 160).is_empty()
        || graph.nodes.values().filter(|n| n.name == node.name).count() != 1
    {
        return None;
    }
    let profile_device = node
        .properties
        .get("card.profile.device")?
        .parse::<i32>()
        .ok()
        .filter(|v| *v >= 0)?;
    let mut active_routes = catalog
        .active_routes
        .values()
        .filter(|(_, d)| *d == profile_device);
    let active_route = active_routes.next().map(|(r, _)| *r);
    if active_routes.next().is_some() {
        return None;
    }
    let mut choices: Vec<_> = catalog
        .ports
        .values()
        .filter(|p| {
            p.direction
                == if direction == "output" {
                    spa::sys::SPA_DIRECTION_OUTPUT
                } else {
                    spa::sys::SPA_DIRECTION_INPUT
                }
                && p.devices.contains(&profile_device)
                && (p.available || Some(p.index) == active_route)
        })
        .collect();
    choices.sort_by_key(|p| std::cmp::Reverse(p.priority));
    let mut seen = BTreeSet::new();
    let mut route_ids = BTreeSet::new();
    if choices
        .iter()
        .any(|p| !seen.insert(&p.name) || !route_ids.insert(p.index))
    {
        return None;
    }
    let active = choices
        .iter()
        .find(|p| Some(p.index) == active_route)
        .copied();
    Some(Endpoint {
        device,
        profile_device,
        direction,
        active,
        choices,
    })
}

pub fn port_identity(graph: &Graph, direction: &str, name: &str) -> Option<Identity> {
    if !graph.ready || !graph.connected {
        return None;
    }
    graph.nodes.values().find_map(|node| {
        if node.name != name
            || node.serial.is_empty()
            || endpoint(graph, node)?.direction != direction
        {
            return None;
        }
        Some(Identity {
            generation: graph.generation.clone(),
            id: node.id,
            serial: node.serial.clone(),
        })
    })
}

pub(super) struct Card<'a> {
    pub bluetooth: bool,
    pub active: Option<&'a Profile>,
    pub choices: Vec<&'a Profile>,
}

pub(super) fn card<'a>(graph: &Graph, device: &'a Device) -> Option<Card<'a>> {
    let name = device.properties.get("device.name")?;
    if identifier(&json!(name), 160).is_empty()
        || graph
            .devices
            .values()
            .filter(|d| d.properties.get("device.name") == Some(name))
            .count()
            != 1
    {
        return None;
    }
    let catalog = &device.catalog;
    let mut ids = BTreeSet::new();
    let mut names = BTreeSet::new();
    if catalog.active_profile.len() > 1
        || catalog
            .profiles
            .values()
            .any(|p| !ids.insert(p.index) || !names.insert(&p.name))
    {
        return None;
    }
    let active = catalog
        .profiles
        .values()
        .find(|p| Some(p.index) == catalog.profile());
    let bluetooth = device
        .properties
        .get("device.api")
        .is_some_and(|v| v == "bluez5");
    let choices = catalog
        .profiles
        .values()
        .filter(|p| {
            let is_active = Some(p.index) == catalog.profile();
            (is_active || p.available)
                && (is_active
                    || p.name == "off"
                    || bluetooth
                    || [
                        (spa::sys::SPA_DIRECTION_OUTPUT, p.sinks),
                        (spa::sys::SPA_DIRECTION_INPUT, p.sources),
                    ]
                    .iter()
                    .all(|(direction, count)| {
                        *count == 0
                            || catalog.ports.values().any(|port| {
                                port.priority > 0
                                    && port.direction == *direction
                                    && port.profiles.contains(&p.index)
                            })
                    }))
        })
        .collect();
    Some(Card {
        bluetooth,
        active,
        choices,
    })
}

pub fn profile_identity(graph: &Graph, name: &str) -> Option<Identity> {
    if !graph.ready || !graph.connected {
        return None;
    }
    let device = graph
        .devices
        .values()
        .find(|d| d.properties.get("device.name").is_some_and(|n| n == name))?;
    card(graph, device)?;
    let serial = device
        .properties
        .get("object.serial")
        .filter(|s| !s.is_empty())?;
    Some(Identity {
        generation: graph.generation.clone(),
        id: device.id,
        serial: serial.clone(),
    })
}

pub fn snapshot(graph: &Graph) -> (Json, Json) {
    let mut cards = vec![];
    let mut ports = vec![];
    for device in graph.devices.values().take(128) {
        let props = &device.properties;
        let name = identifier(&json!(props.get("device.name")), 160);
        if name.is_empty()
            || graph
                .devices
                .values()
                .filter(|d| d.properties.get("device.name") == Some(&name))
                .count()
                != 1
        {
            continue;
        }
        let Some(card) = card(graph, device) else {
            continue;
        };
        let bluetooth = card.bluetooth;
        let active_name = card.active.map(|p| p.name.as_str()).unwrap_or("off");
        let mut profiles = card.choices;
        profiles.sort_by_key(|p| (std::cmp::Reverse(p.priority), p.label.to_lowercase()));
        let mut seen = BTreeSet::new();
        let profiles: Vec<_> = profiles
            .into_iter()
            .filter(|p| seen.insert(p.name.clone()))
            .take(64)
            .map(|p| json!({"value":p.name,"label":p.label,"sinks":p.sinks,"sources":p.sources}))
            .collect();
        if !profiles.is_empty() {
            let description = label(
                &json!(
                    props
                        .get("device.description")
                        .or_else(|| props.get("device.alias"))
                ),
                160,
            );
            cards.push(json!({"name":name,"identity":{"generation":graph.generation,"id":device.id,"serial":props.get("object.serial").cloned().unwrap_or_default()},"label":if description.is_empty() {&name} else {&description},
                "bluetooth":bluetooth,"address":identifier(&json!(props.get("api.bluez5.address").or_else(|| props.get("device.string"))),80),
                "activeProfile":active_name,"profiles":profiles}));
        }
        for node in graph.nodes.values() {
            if node
                .properties
                .get("device.id")
                .and_then(|v| v.parse::<u32>().ok())
                != Some(device.id)
            {
                continue;
            }
            let Some(endpoint) = endpoint(graph, node) else {
                continue;
            };
            let direction = endpoint.direction;
            let choices = &endpoint.choices;
            let active_port = endpoint.active.map(|p| p.name.as_str()).unwrap_or("");
            if choices.len() > 1 {
                let description = label(&json!(node.properties.get("node.description")), 160);
                ports.push(json!({"direction":direction,"endpoint":node.name,
                    "identity":{"generation":graph.generation,"id":node.id,"serial":node.serial},
                    "label":if description.is_empty() {&node.name} else {&description},"activePort":active_port,
                    "ports":choices.iter().take(64).map(|p| json!({"value":p.name,"label":p.label})).collect::<Vec<_>>()}));
            }
        }
    }
    cards.sort_by_key(|c| {
        (
            c["activeProfile"] == "off",
            c["label"].as_str().unwrap_or("").to_lowercase(),
        )
    });
    cards.truncate(64);
    ports.sort_by_key(|p| p["direction"] == "input");
    ports.truncate(128);
    (json!(cards), json!(ports))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::native::{Device, Node};
    use spa::pod::Property;
    use std::sync::Arc;

    fn profile(index: i32, name: &str) -> Object {
        Object {
            type_: spa::sys::SPA_TYPE_OBJECT_ParamProfile,
            id: spa::sys::SPA_PARAM_EnumProfile,
            properties: vec![
                Property::new(spa::sys::SPA_PARAM_PROFILE_index, Value::Int(index)),
                Property::new(spa::sys::SPA_PARAM_PROFILE_name, Value::String(name.into())),
            ],
        }
    }
    fn graph(catalog: Catalog) -> Graph {
        Graph {
            ready: true,
            devices: BTreeMap::from([(
                42,
                Device {
                    id: 42,
                    catalog_ready: true,
                    catalog: Arc::new(catalog),
                    properties: BTreeMap::from([("device.name".into(), "card".into())]),
                    ..Device::default()
                },
            )]),
            ..Graph::default()
        }
    }
    #[test]
    fn profiles_reject_ambiguous_or_unsafe_identities() {
        let mut catalog = Catalog::default();
        for (index, value) in [
            profile(0, "off"),
            profile(1, "bad\u{202e}name"),
            profile(-1, "negative"),
        ]
        .iter()
        .enumerate()
        {
            catalog.read(spa::sys::SPA_PARAM_EnumProfile, index as u32, value);
        }
        let mut duplicate = profile(2, "duplicate");
        duplicate.properties.push(Property::new(
            spa::sys::SPA_PARAM_PROFILE_index,
            Value::Int(3),
        ));
        catalog.read(spa::sys::SPA_PARAM_EnumProfile, 3, &duplicate);
        assert_eq!(catalog.profiles.len(), 1);
        catalog.read(
            spa::sys::SPA_PARAM_EnumProfile,
            256,
            &profile(4, "overflow"),
        );
        assert_eq!(
            snapshot(&graph(catalog.clone())).0[0]["profiles"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        catalog.read(
            spa::sys::SPA_PARAM_EnumProfile,
            4,
            &profile(0, "same-index"),
        );
        assert_eq!(snapshot(&graph(catalog)).0, json!([]));
    }
    #[test]
    fn bluetooth_profiles_need_no_alsa_ports_and_labels_are_cleaned() {
        let mut catalog = Catalog::default();
        let mut object = profile(1, "a2dp-sink-aac");
        object.properties.push(Property::new(
            spa::sys::SPA_PARAM_PROFILE_description,
            Value::String(" AAC\nHeadphones\u{202e} ".into()),
        ));
        object.properties.push(Property::new(
            spa::sys::SPA_PARAM_PROFILE_classes,
            Value::Struct(vec![
                Value::Int(1),
                Value::Struct(vec![Value::String("Audio/Sink".into()), Value::Int(1)]),
            ]),
        ));
        catalog.read(spa::sys::SPA_PARAM_EnumProfile, 0, &object);
        let mut graph = graph(catalog);
        assert_eq!(snapshot(&graph).0, json!([]));
        graph
            .devices
            .get_mut(&42)
            .unwrap()
            .properties
            .insert("device.api".into(), "bluez5".into());
        let (cards, _) = snapshot(&graph);
        assert_eq!(cards[0]["bluetooth"], true);
        assert_eq!(cards[0]["profiles"][0]["label"], "AAC Headphones");
        assert_eq!(cards[0]["profiles"][0]["sinks"], 1);
    }
    #[test]
    fn ports_exclude_monitors_and_ambiguous_targets() {
        let catalog = Catalog {
            ports: [(0, "mic"), (1, "line")]
                .map(|(i, name)| {
                    (
                        i,
                        Port {
                            index: i as i32,
                            name: name.into(),
                            label: name.into(),
                            direction: spa::sys::SPA_DIRECTION_INPUT,
                            priority: 1,
                            available: true,
                            profiles: vec![],
                            devices: vec![0],
                        },
                    )
                })
                .into(),
            ..Catalog::default()
        };
        let mut graph = graph(catalog);
        graph.nodes.insert(
            50,
            Node {
                id: 50,
                name: "source".into(),
                properties: BTreeMap::from([
                    ("media.class".into(), "Audio/Source".into()),
                    ("device.id".into(), "42".into()),
                    ("card.profile.device".into(), "0".into()),
                ]),
                ..Node::default()
            },
        );
        assert_eq!(snapshot(&graph).1.as_array().unwrap().len(), 1);
        graph
            .nodes
            .get_mut(&50)
            .unwrap()
            .properties
            .insert("device.class".into(), "Monitor".into());
        assert_eq!(snapshot(&graph).1, json!([]));
        graph
            .nodes
            .get_mut(&50)
            .unwrap()
            .properties
            .remove("device.class");
        graph.nodes.insert(51, graph.nodes[&50].clone());
        assert_eq!(snapshot(&graph).1, json!([]));
        graph.nodes.remove(&51);
        let catalog = Arc::make_mut(&mut graph.devices.get_mut(&42).unwrap().catalog);
        catalog.ports.get_mut(&1).unwrap().name = "mic".into();
        assert_eq!(snapshot(&graph).1, json!([]));
    }
}
