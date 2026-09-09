//! Hardware endpoints use device Route properties; virtual nodes use node Props.
use super::{Audio, AudioPatch, Graph, Node};
use crate::protocol::{Failure, Result};
use pipewire::spa;
use std::io::Cursor;

#[derive(Clone, Debug)]
pub(super) struct Route {
    pub index: i32,
    pub device: i32,
    pub audio: Audio,
}

pub(super) fn route_for<'a>(graph: &'a Graph, node: &Node) -> Option<(u32, &'a Route)> {
    let device_id = node.properties.get("device.id")?.parse().ok()?;
    let profile_device: i32 = node.properties.get("card.profile.device")?.parse().ok()?;
    graph
        .devices
        .get(&device_id)?
        .routes
        .values()
        .find(|route| route.device == profile_device)
        .map(|route| (device_id, route))
}

pub(super) fn read_route(pod: &spa::pod::Pod) -> Option<Route> {
    if pod.as_bytes().len() > 65536 {
        return None;
    }
    use spa::pod::Value;
    let (_, Value::Object(object)) =
        spa::pod::deserialize::PodDeserializer::deserialize_any_from(pod.as_bytes()).ok()?
    else {
        return None;
    };
    let (mut index, mut device, mut audio) = (None, None, None);
    for property in object.properties {
        match (property.key, property.value) {
            (spa::sys::SPA_PARAM_ROUTE_index, Value::Int(value)) if value >= 0 => {
                index = Some(value)
            }
            (spa::sys::SPA_PARAM_ROUTE_device, Value::Int(value)) if value >= 0 => {
                device = Some(value)
            }
            (spa::sys::SPA_PARAM_ROUTE_props, Value::Object(props)) => {
                let mut value = Audio::default();
                read_properties(&mut value, props);
                if !value.volumes.is_empty() {
                    audio = Some(value);
                }
            }
            _ => (),
        }
    }
    Some(Route {
        index: index?,
        device: device?,
        audio: audio?,
    })
}

pub(super) fn read_audio(audio: &mut Audio, pod: &spa::pod::Pod) {
    if pod.as_bytes().len() > 65536 {
        return;
    }
    let Ok((_, spa::pod::Value::Object(object))) =
        spa::pod::deserialize::PodDeserializer::deserialize_any_from(pod.as_bytes())
    else {
        return;
    };
    read_properties(audio, object);
}

fn read_properties(audio: &mut Audio, object: spa::pod::Object) {
    use spa::pod::{Value, ValueArray};
    for property in object.properties {
        match (property.key, property.value) {
            (spa::sys::SPA_PROP_mute, Value::Bool(muted)) => audio.muted = Some(muted),
            (spa::sys::SPA_PROP_channelVolumes, Value::ValueArray(ValueArray::Float(volumes))) => {
                if volumes.len() <= 64 && volumes.iter().all(|v| v.is_finite() && *v >= 0.0) {
                    audio.volumes = volumes.into_iter().map(|v| f64::from(v).cbrt()).collect();
                }
            }
            (spa::sys::SPA_PROP_channelMap, Value::ValueArray(ValueArray::Id(channels)))
                if channels.len() <= 64 =>
            {
                audio.channels = channels.into_iter().map(|id| id.0).collect();
            }
            _ => (),
        }
    }
}
pub(super) fn patch_pod(patch: &AudioPatch, route: Option<&Route>) -> Result<Vec<u8>> {
    use spa::pod::{Object, Property, Value, ValueArray};
    let mut properties = Vec::new();
    if let Some(muted) = patch.muted {
        properties.push(Property::new(spa::sys::SPA_PROP_mute, Value::Bool(muted)));
    }
    if let Some(volumes) = &patch.volumes {
        properties.push(Property::new(
            spa::sys::SPA_PROP_channelVolumes,
            Value::ValueArray(ValueArray::Float(
                volumes.iter().map(|v| v.powi(3) as f32).collect(),
            )),
        ));
    }
    let mut value = Value::Object(Object {
        type_: spa::sys::SPA_TYPE_OBJECT_Props,
        id: spa::param::ParamType::Props.as_raw(),
        properties,
    });
    if let Some(route) = route {
        value = Value::Object(Object {
            type_: spa::sys::SPA_TYPE_OBJECT_ParamRoute,
            id: spa::param::ParamType::Route.as_raw(),
            properties: vec![
                Property::new(spa::sys::SPA_PARAM_ROUTE_index, Value::Int(route.index)),
                Property::new(spa::sys::SPA_PARAM_ROUTE_device, Value::Int(route.device)),
                Property::new(spa::sys::SPA_PARAM_ROUTE_props, value),
                Property::new(spa::sys::SPA_PARAM_ROUTE_save, Value::Bool(true)),
            ],
        });
    }
    let (output, _) =
        spa::pod::serialize::PodSerializer::serialize(Cursor::new(Vec::new()), &value)
            .map_err(|_| Failure::new("invalid_params", "Could not encode audio properties"))?;
    Ok(output.into_inner())
}
