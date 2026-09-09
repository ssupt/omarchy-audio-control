//! All libpipewire proxies and callbacks live on one dedicated thread. Only
//! owned snapshots and typed commands cross into the asynchronous control service.
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::io::Cursor;
use std::rc::Rc;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::time::Duration;

use crate::protocol::{Failure, Result};
use pipewire as pw;
use pw::spa;
use serde::{Deserialize, Serialize};
use tokio::sync::{Semaphore, oneshot, watch};

type Properties = BTreeMap<String, String>;

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Audio {
    pub muted: Option<bool>,
    /// Perceptual/cubic volumes, matching the UI. SPA stores their cubes.
    pub volumes: Vec<f64>,
    pub channels: Vec<u32>,
}
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub id: u32,
    pub serial: String,
    pub name: String,
    pub properties: Properties,
    pub state: String,
    pub audio: Audio,
}
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub id: u32,
    pub revision: u64,
    pub properties: Properties,
}
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Link {
    pub id: u32,
    pub output_node: u32,
    pub input_node: u32,
    pub state: String,
}
#[derive(Clone, Debug, Default, Serialize)]
pub struct MetadataValue {
    pub subject: u32,
    pub key: String,
    pub value: String,
    pub type_: String,
}
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Graph {
    pub generation: String,
    pub revision: u64,
    pub connected: bool,
    pub ready: bool,
    pub nodes: BTreeMap<u32, Node>,
    pub devices: BTreeMap<u32, Device>,
    pub links: BTreeMap<u32, Link>,
    pub metadata: BTreeMap<String, BTreeMap<String, MetadataValue>>,
    pub error: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    pub generation: String,
    pub id: u32,
    pub serial: String,
}
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AudioPatch {
    pub muted: Option<bool>,
    pub volumes: Option<Vec<f64>>,
}

struct Command {
    identity: Identity,
    patch: AudioPatch,
    reply: oneshot::Sender<Result<()>>,
    _permit: tokio::sync::OwnedSemaphorePermit,
}
enum Message {
    Patch(Command),
    Stop,
}
type SenderSlot = Arc<Mutex<Option<pw::channel::Sender<Message>>>>;

struct Inner {
    sender: SenderSlot,
    stopping: Arc<AtomicBool>,
    thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    permits: Arc<Semaphore>,
}
impl Drop for Inner {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Relaxed);
        if let Some(sender) = self.sender.lock().unwrap().as_ref() {
            let _ = sender.send(Message::Stop);
        }
        if let Some(thread) = self.thread.lock().unwrap().take() {
            let _ = thread.join();
        }
    }
}
#[derive(Clone)]
pub struct Handle {
    inner: Arc<Inner>,
    state: watch::Receiver<Arc<Graph>>,
}
impl Handle {
    pub fn start() -> std::io::Result<Self> {
        let (tx, state) = watch::channel(Arc::new(Graph::default()));
        let sender = Arc::new(Mutex::new(None));
        let stopping = Arc::new(AtomicBool::new(false));
        let inner = Arc::new(Inner {
            sender: sender.clone(),
            stopping: stopping.clone(),
            thread: Mutex::new(None),
            permits: Arc::new(Semaphore::new(32)),
        });
        let thread = std::thread::Builder::new()
            .name("audio-pipewire".into())
            .spawn(move || {
                pw::init();
                while !stopping.load(Ordering::Relaxed) {
                    let result = session(tx.clone(), sender.clone(), stopping.clone());
                    *sender.lock().unwrap() = None;
                    let mut disconnected = Graph::default();
                    if let Err(error) = result {
                        disconnected.error = error.to_string();
                    }
                    tx.send_replace(Arc::new(disconnected));
                    for _ in 0..10 {
                        if stopping.load(Ordering::Relaxed) {
                            return;
                        }
                        std::thread::sleep(Duration::from_millis(100));
                    }
                }
            })?;
        *inner.thread.lock().unwrap() = Some(thread);
        Ok(Self { inner, state })
    }
    pub fn subscribe(&self) -> watch::Receiver<Arc<Graph>> {
        self.state.clone()
    }
    pub fn snapshot(&self) -> Arc<Graph> {
        self.state.borrow().clone()
    }
    pub async fn patch(&self, identity: Identity, patch: AudioPatch) -> Result<()> {
        let permit = self
            .inner
            .permits
            .clone()
            .try_acquire_owned()
            .map_err(|_| Failure::new("busy", "Native command queue is full"))?;
        validate_identity(&self.snapshot(), &identity)?;
        validate_patch(&patch)?;
        let (reply, receive) = oneshot::channel();
        let sender = self
            .inner
            .sender
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| Failure::new("disconnected", "PipeWire is unavailable"))?;
        sender
            .send(Message::Patch(Command {
                identity,
                patch,
                reply,
                _permit: permit,
            }))
            .map_err(|_| Failure::new("disconnected", "PipeWire is unavailable"))?;
        tokio::time::timeout(Duration::from_secs(3), receive)
            .await
            .map_err(|_| Failure::unknown("PipeWire did not acknowledge the command"))?
            .map_err(|_| Failure::unknown("PipeWire disconnected during the command"))?
    }
}

pub fn validate_identity<'a>(graph: &'a Graph, identity: &Identity) -> Result<&'a Node> {
    if !graph.ready || !graph.connected || graph.generation != identity.generation {
        return Err(Failure::new(
            "stale_graph",
            "Audio graph changed; refresh before retrying",
        ));
    }
    graph
        .nodes
        .get(&identity.id)
        .filter(|node| !identity.serial.is_empty() && node.serial == identity.serial)
        .ok_or_else(|| Failure::new("stale_node", "Audio device or stream has been replaced"))
}
fn validate_patch(patch: &AudioPatch) -> Result<()> {
    if patch.muted.is_none() && patch.volumes.is_none() {
        return Err(Failure::new("invalid_params", "Empty audio change"));
    }
    if let Some(volumes) = &patch.volumes {
        if volumes.is_empty()
            || volumes.len() > 64
            || volumes
                .iter()
                .any(|v| !v.is_finite() || !(0.0..=1.5).contains(v))
        {
            return Err(Failure::new("invalid_params", "Invalid channel volumes"));
        }
    }
    Ok(())
}

fn copy_props(props: Option<&spa::utils::dict::DictRef>) -> Properties {
    props
        .into_iter()
        .flat_map(|p| p.iter())
        .take(128)
        .filter(|(key, value)| key.len() <= 128 && value.len() <= 2048)
        .map(|(key, value)| (key.into(), value.into()))
        .collect()
}
fn publish(graph: &Rc<RefCell<Graph>>, tx: &watch::Sender<Arc<Graph>>) {
    let mut graph = graph.borrow_mut();
    graph.revision = graph.revision.wrapping_add(1);
    tx.send_replace(Arc::new(graph.clone()));
}
fn update_node(node: &mut Node, props: Properties) {
    node.properties.extend(props);
    node.name = node
        .properties
        .get("node.name")
        .cloned()
        .unwrap_or_default();
    node.serial = node
        .properties
        .get("object.serial")
        .cloned()
        .unwrap_or_default();
}
fn read_audio(audio: &mut Audio, pod: &spa::pod::Pod) {
    if pod.as_bytes().len() > 65536 {
        return;
    }
    let Ok((_, spa::pod::Value::Object(object))) =
        spa::pod::deserialize::PodDeserializer::deserialize_any_from(pod.as_bytes())
    else {
        return;
    };
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
fn patch_pod(patch: &AudioPatch) -> Result<Vec<u8>> {
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
    let value = Value::Object(Object {
        type_: spa::sys::SPA_TYPE_OBJECT_Props,
        id: spa::param::ParamType::Props.as_raw(),
        properties,
    });
    let (output, _) =
        spa::pod::serialize::PodSerializer::serialize(Cursor::new(Vec::new()), &value)
            .map_err(|_| Failure::new("invalid_params", "Could not encode audio properties"))?;
    Ok(output.into_inner())
}

struct OwnedNode {
    _listener: pw::node::NodeListener,
    node: pw::node::Node,
}
struct OwnedMetadata {
    _listener: pw::metadata::MetadataListener,
    _metadata: pw::metadata::Metadata,
    name: String,
}
struct OwnedDevice {
    _listener: pw::device::DeviceListener,
    _device: pw::device::Device,
}
struct OwnedLink {
    _listener: pw::link::LinkListener,
    _link: pw::link::Link,
}
#[derive(Default)]
struct Proxies {
    nodes: BTreeMap<u32, OwnedNode>,
    metadata: BTreeMap<u32, OwnedMetadata>,
    devices: BTreeMap<u32, OwnedDevice>,
    links: BTreeMap<u32, OwnedLink>,
}

fn session(
    tx: watch::Sender<Arc<Graph>>,
    sender: SenderSlot,
    stopping: Arc<AtomicBool>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let main_loop = pw::main_loop::MainLoopRc::new(None)?;
    let context = pw::context::ContextRc::new(&main_loop, None)?;
    let core = context.connect_rc(Some(pw::properties::properties! {
        "application.name" => "Advanced Audio Control",
        "application.id" => "ssupt.audio-control",
        "media.category" => "Manager"
    }))?;
    let registry = core.get_registry_rc()?;
    let graph = Rc::new(RefCell::new(Graph {
        generation: std::fs::read_to_string("/proc/sys/kernel/random/uuid")?
            .trim()
            .into(),
        connected: true,
        ..Graph::default()
    }));
    let proxies = Rc::new(RefCell::new(Proxies::default()));
    let pending = Rc::new(RefCell::new(BTreeMap::<i32, Command>::new()));
    let initial = Rc::new(Cell::new(core.sync(0)?.raw()));
    let sync_round = Rc::new(Cell::new(0));
    let _core_listener = {
        let graph = graph.clone();
        let tx = tx.clone();
        let pending = pending.clone();
        let initial = initial.clone();
        let core = core.downgrade();
        let loop_ = main_loop.downgrade();
        core.upgrade()
            .unwrap()
            .add_listener_local()
            .done(move |id, seq| {
                if id != pw::core::PW_ID_CORE {
                    return;
                }
                if seq.raw() == initial.get() {
                    if sync_round.get() == 0 {
                        sync_round.set(1);
                        if let Some(core) = core.upgrade() {
                            if let Ok(seq) = core.sync(0) {
                                initial.set(seq.raw());
                            }
                        }
                    } else {
                        graph.borrow_mut().ready = true;
                        publish(&graph, &tx);
                    }
                }
                if let Some(command) = pending.borrow_mut().remove(&seq.raw()) {
                    // A roundtrip is an ordering barrier, not proof of the requested
                    // state. Verify the subscribed properties before acknowledging.
                    let result = verify_patch(&graph.borrow(), &command.identity, &command.patch);
                    let _ = command.reply.send(result);
                }
            })
            .error(move |id, _, _, _| {
                if id == pw::core::PW_ID_CORE {
                    if let Some(loop_) = loop_.upgrade() {
                        loop_.quit();
                    }
                }
            })
            .register()
    };
    let _registry_listener = {
        let registry = registry.downgrade();
        let graph_added = graph.clone();
        let proxies_added = proxies.clone();
        let tx_added = tx.clone();
        let graph_removed = graph.clone();
        let proxies_removed = proxies.clone();
        let tx_removed = tx.clone();
        registry
            .upgrade()
            .unwrap()
            .add_listener_local()
            .global(move |global| {
                let Some(registry) = registry.upgrade() else {
                    return;
                };
                let id = global.id;
                if graph_added.borrow().nodes.len()
                    + graph_added.borrow().devices.len()
                    + graph_added.borrow().links.len()
                    >= 8192
                {
                    return;
                }
                let props = copy_props(global.props);
                match global.type_ {
                    pw::types::ObjectType::Node => {
                        let Ok(node) = registry.bind::<pw::node::Node, _>(global) else {
                            return;
                        };
                        let mut snapshot = Node {
                            id,
                            ..Node::default()
                        };
                        update_node(&mut snapshot, props);
                        graph_added.borrow_mut().nodes.insert(id, snapshot);
                        let g = graph_added.clone();
                        let t = tx_added.clone();
                        let gp = graph_added.clone();
                        let tp = tx_added.clone();
                        let listener = node
                            .add_listener_local()
                            .info(move |info| {
                                if let Some(node) = g.borrow_mut().nodes.get_mut(&id) {
                                    update_node(node, copy_props(info.props()));
                                    node.state = format!("{:?}", info.state());
                                }
                                publish(&g, &t);
                            })
                            .param(move |_, param, _, _, pod| {
                                if param == spa::param::ParamType::Props {
                                    if let Some(pod) = pod {
                                        if let Some(node) = gp.borrow_mut().nodes.get_mut(&id) {
                                            read_audio(&mut node.audio, pod);
                                        }
                                        publish(&gp, &tp);
                                    }
                                }
                            })
                            .register();
                        node.subscribe_params(&[spa::param::ParamType::Props]);
                        proxies_added.borrow_mut().nodes.insert(
                            id,
                            OwnedNode {
                                _listener: listener,
                                node,
                            },
                        );
                    }
                    pw::types::ObjectType::Metadata => {
                        let name = props.get("metadata.name").cloned().unwrap_or_default();
                        if name.is_empty() || name.len() > 128 {
                            return;
                        }
                        let Ok(metadata) = registry.bind::<pw::metadata::Metadata, _>(global)
                        else {
                            return;
                        };
                        let g = graph_added.clone();
                        let t = tx_added.clone();
                        let n = name.clone();
                        let listener = metadata
                            .add_listener_local()
                            .property(move |subject, key, type_, value| {
                                {
                                    let mut graph = g.borrow_mut();
                                    let store = graph.metadata.entry(n.clone()).or_default();
                                    match (key, value) {
                                        (Some(key), Some(value))
                                            if key.len() <= 256
                                                && value.len() <= 16384
                                                && store.len() < 8192 =>
                                        {
                                            store.insert(
                                                format!("{subject}:{key}"),
                                                MetadataValue {
                                                    subject,
                                                    key: key.into(),
                                                    value: value.into(),
                                                    type_: type_.unwrap_or("").into(),
                                                },
                                            );
                                        }
                                        (Some(key), None) => {
                                            store.remove(&format!("{subject}:{key}"));
                                        }
                                        (None, _) => {
                                            store.retain(|_, value| value.subject != subject)
                                        }
                                        _ => (),
                                    }
                                }
                                publish(&g, &t);
                                0
                            })
                            .register();
                        proxies_added.borrow_mut().metadata.insert(
                            id,
                            OwnedMetadata {
                                _listener: listener,
                                _metadata: metadata,
                                name,
                            },
                        );
                    }
                    pw::types::ObjectType::Device => {
                        let Ok(device) = registry.bind::<pw::device::Device, _>(global) else {
                            return;
                        };
                        graph_added.borrow_mut().devices.insert(
                            id,
                            Device {
                                id,
                                revision: 0,
                                properties: props,
                            },
                        );
                        let g = graph_added.clone();
                        let t = tx_added.clone();
                        let listener = device
                            .add_listener_local()
                            .info(move |info| {
                                if let Some(device) = g.borrow_mut().devices.get_mut(&id) {
                                    device.properties.extend(copy_props(info.props()));
                                }
                                publish(&g, &t);
                            })
                            .param({
                                let g = graph_added.clone();
                                let t = tx_added.clone();
                                move |_, _, _, _, _| {
                                    if let Some(device) = g.borrow_mut().devices.get_mut(&id) {
                                        device.revision += 1;
                                    }
                                    publish(&g, &t);
                                }
                            })
                            .register();
                        device.subscribe_params(&[
                            spa::param::ParamType::Profile,
                            spa::param::ParamType::Route,
                        ]);
                        proxies_added.borrow_mut().devices.insert(
                            id,
                            OwnedDevice {
                                _listener: listener,
                                _device: device,
                            },
                        );
                    }
                    pw::types::ObjectType::Link => {
                        let Ok(link) = registry.bind::<pw::link::Link, _>(global) else {
                            return;
                        };
                        let g = graph_added.clone();
                        let t = tx_added.clone();
                        let listener = link
                            .add_listener_local()
                            .info(move |info| {
                                g.borrow_mut().links.insert(
                                    id,
                                    Link {
                                        id,
                                        output_node: info.output_node_id(),
                                        input_node: info.input_node_id(),
                                        state: format!("{:?}", info.state()),
                                    },
                                );
                                publish(&g, &t);
                            })
                            .register();
                        proxies_added.borrow_mut().links.insert(
                            id,
                            OwnedLink {
                                _listener: listener,
                                _link: link,
                            },
                        );
                    }
                    _ => (),
                }
                publish(&graph_added, &tx_added);
            })
            .global_remove(move |id| {
                let mut proxies = proxies_removed.borrow_mut();
                proxies.nodes.remove(&id);
                proxies.devices.remove(&id);
                proxies.links.remove(&id);
                {
                    let mut graph = graph_removed.borrow_mut();
                    graph.nodes.remove(&id);
                    graph.devices.remove(&id);
                    graph.links.remove(&id);
                    if let Some(metadata) = proxies.metadata.remove(&id) {
                        graph.metadata.remove(&metadata.name);
                    }
                }
                publish(&graph_removed, &tx_removed);
            })
            .register()
    };
    let (command_tx, command_rx) = pw::channel::channel();
    let _commands = {
        let proxies = proxies.clone();
        let graph = graph.clone();
        let core = core.downgrade();
        let loop_weak = main_loop.downgrade();
        let pending = pending.clone();
        command_rx.attach(main_loop.loop_(), move |message| match message {
            Message::Stop => {
                if let Some(loop_) = loop_weak.upgrade() {
                    loop_.quit();
                }
            }
            Message::Patch(command) => {
                let result = (|| {
                    validate_identity(&graph.borrow(), &command.identity)?;
                    validate_patch(&command.patch)?;
                    let data = patch_pod(&command.patch)?;
                    let pod = spa::pod::Pod::from_bytes(&data).ok_or_else(|| {
                        Failure::new("encoding_error", "Invalid audio properties")
                    })?;
                    let proxies = proxies.borrow();
                    let node = proxies
                        .nodes
                        .get(&command.identity.id)
                        .ok_or_else(|| Failure::new("stale_node", "Audio node disappeared"))?;
                    node.node.set_param(spa::param::ParamType::Props, 0, pod);
                    core.upgrade()
                        .ok_or_else(|| Failure::unknown("Audio server disconnected"))?
                        .sync(0)
                        .map_err(|_| Failure::unknown("Audio server disconnected"))
                })();
                match result {
                    Ok(seq) => {
                        pending.borrow_mut().insert(seq.raw(), command);
                    }
                    Err(error) => {
                        let _ = command.reply.send(Err(error));
                    }
                }
            }
        })
    };
    *sender.lock().unwrap() = Some(command_tx);
    publish(&graph, &tx);
    if !stopping.load(Ordering::Relaxed) {
        main_loop.run();
    }
    *sender.lock().unwrap() = None;
    Ok(())
}

fn verify_patch(graph: &Graph, identity: &Identity, patch: &AudioPatch) -> Result<()> {
    let node = validate_identity(graph, identity)
        .map_err(|_| Failure::unknown("Audio node changed during the operation"))?;
    if patch.muted.is_some() && node.audio.muted != patch.muted {
        return Err(Failure::unknown("Audio mute change was not confirmed"));
    }
    if let Some(volumes) = &patch.volumes {
        if volumes.len() != node.audio.volumes.len()
            || volumes
                .iter()
                .zip(&node.audio.volumes)
                .any(|(a, b)| (a - b).abs() > 0.015)
        {
            return Err(Failure::unknown("Audio volume change was not confirmed"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_serials_and_generations_cannot_target_successor_nodes() {
        let mut graph = Graph {
            connected: true,
            ready: true,
            generation: "session".into(),
            ..Graph::default()
        };
        graph.nodes.insert(
            42,
            Node {
                id: 42,
                serial: "9007199254740993".into(),
                ..Node::default()
            },
        );
        let mut identity = Identity {
            id: 42,
            serial: "9007199254740993".into(),
            generation: "session".into(),
        };
        assert!(validate_identity(&graph, &identity).is_ok());
        identity.serial = "9007199254740992".into();
        assert!(validate_identity(&graph, &identity).is_err());
        identity.serial = "9007199254740993".into();
        identity.generation = "previous".into();
        assert!(validate_identity(&graph, &identity).is_err());
    }
    #[test]
    fn native_volume_encoding_preserves_perceptual_levels() {
        let patch = AudioPatch {
            muted: Some(true),
            volumes: Some(vec![0.2, 1.5]),
        };
        let bytes = patch_pod(&patch).unwrap();
        let mut audio = Audio::default();
        read_audio(&mut audio, spa::pod::Pod::from_bytes(&bytes).unwrap());
        assert_eq!(audio.muted, Some(true));
        assert!((audio.volumes[0] - 0.2).abs() < 0.0001);
        assert!((audio.volumes[1] - 1.5).abs() < 0.0001);
        assert!(
            validate_patch(&AudioPatch {
                volumes: Some(vec![f64::NAN]),
                muted: None
            })
            .is_err()
        );
    }
}
