//! All libpipewire proxies and callbacks live on one dedicated thread. Only
//! owned snapshots and typed commands cross into the asynchronous control service.
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
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

mod audio;
pub mod metadata;
use audio::{patch_pod, read_audio, read_route, route_for};

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
    #[serde(skip)]
    routes: BTreeMap<u32, audio::Route>,
    #[serde(skip)]
    route_request: Option<i32>,
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
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
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
    #[serde(skip)]
    pub metadata_ids: BTreeMap<String, u32>,
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
    completion: Completion,
}
struct Completion {
    reply: oneshot::Sender<Result<()>>,
    _permit: tokio::sync::OwnedSemaphorePermit,
}
enum Message {
    Patch(Command),
    Metadata(metadata::Command),
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
        let mut state = self.subscribe();
        let expected_identity = identity.clone();
        let expected_patch = patch.clone();
        sender
            .send(Message::Patch(Command {
                identity,
                patch,
                completion: Completion {
                    reply,
                    _permit: permit,
                },
            }))
            .map_err(|_| Failure::new("disconnected", "PipeWire is unavailable"))?;
        tokio::time::timeout(Duration::from_secs(3), async {
            receive
                .await
                .map_err(|_| Failure::unknown("PipeWire disconnected during the command"))??;
            loop {
                let graph = state.borrow_and_update().clone();
                validate_identity(&graph, &expected_identity)
                    .map_err(|_| Failure::unknown("Audio node changed during the operation"))?;
                if verify_patch(&graph, &expected_identity, &expected_patch).is_ok() {
                    return Ok(());
                }
                state
                    .changed()
                    .await
                    .map_err(|_| Failure::unknown("PipeWire disconnected during the command"))?;
            }
        })
        .await
        .map_err(|_| Failure::unknown("Audio change was not confirmed by PipeWire"))?
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
    let mut snapshot = graph.clone();
    for node in snapshot.nodes.values_mut() {
        if let Some((_, route)) = route_for(&graph, node) {
            node.audio = route.audio.clone();
        }
    }
    tx.send_replace(Arc::new(snapshot));
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

struct OwnedNode {
    _listener: pw::node::NodeListener,
    node: pw::node::Node,
}
struct OwnedMetadata {
    _listener: pw::metadata::MetadataListener,
    metadata: pw::metadata::Metadata,
    name: String,
}
struct OwnedDevice {
    _listener: pw::device::DeviceListener,
    device: pw::device::Device,
    param_flags: BTreeMap<u32, u32>,
    route_params: BTreeMap<u32, audio::Route>,
    route_dirty: bool,
    route_readable: bool,
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

// Keep one enumeration per device in flight. Commit the complete result at its
// barrier so route removal and duplex updates cannot leave stale entries.
fn refresh_routes(
    id: u32,
    proxies: &Rc<RefCell<Proxies>>,
    graph: &Rc<RefCell<Graph>>,
    core: &pw::core::CoreRc,
    syncs: &Rc<RefCell<BTreeMap<i32, u32>>>,
) {
    let mut proxies = proxies.borrow_mut();
    let mut graph = graph.borrow_mut();
    let (Some(device), Some(snapshot)) = (proxies.devices.get_mut(&id), graph.devices.get_mut(&id))
    else {
        return;
    };
    if !device.route_dirty || snapshot.route_request.is_some() {
        return;
    }
    device.route_dirty = false;
    device.route_params.clear();
    if device.route_readable {
        device
            .device
            .enum_params(0, Some(spa::param::ParamType::Route), 0, 256);
    }
    if let Ok(done) = core.sync(0) {
        snapshot.route_request = Some(done.raw());
        syncs.borrow_mut().insert(done.raw(), id);
    }
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
    let pending = Rc::new(RefCell::new(BTreeMap::<i32, Completion>::new()));
    let route_syncs = Rc::new(RefCell::new(BTreeMap::<i32, u32>::new()));
    let initial = Rc::new(Cell::new(core.sync(0)?.raw()));
    let sync_round = Rc::new(Cell::new(0));
    let _core_listener = {
        let graph = graph.clone();
        let tx = tx.clone();
        let pending = pending.clone();
        let initial = initial.clone();
        let proxies = Rc::downgrade(&proxies);
        let route_syncs = route_syncs.clone();
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
                        sync_round.set(2);
                        let ready = graph
                            .borrow()
                            .devices
                            .values()
                            .all(|d| d.route_request.is_none());
                        graph.borrow_mut().ready = ready;
                        publish(&graph, &tx);
                    }
                }
                let refreshed = route_syncs.borrow_mut().remove(&seq.raw());
                if let (Some(id), Some(proxies)) = (refreshed, proxies.upgrade()) {
                    if let Some(device) = proxies.borrow_mut().devices.get_mut(&id) {
                        if let Some(snapshot) = graph.borrow_mut().devices.get_mut(&id) {
                            if snapshot.route_request != Some(seq.raw()) {
                                return;
                            }
                            snapshot.route_request = None;
                            if !device.route_dirty {
                                let topology = |routes: &BTreeMap<u32, audio::Route>| {
                                    routes
                                        .values()
                                        .map(|r| (r.index, r.device))
                                        .collect::<Vec<_>>()
                                };
                                if topology(&snapshot.routes) != topology(&device.route_params) {
                                    snapshot.revision += 1;
                                }
                                snapshot.routes = std::mem::take(&mut device.route_params);
                            }
                        }
                    }
                    if let Some(core) = core.upgrade() {
                        refresh_routes(id, &proxies, &graph, &core, &route_syncs);
                    }
                    if sync_round.get() == 2
                        && graph
                            .borrow()
                            .devices
                            .values()
                            .all(|d| d.route_request.is_none())
                    {
                        graph.borrow_mut().ready = true;
                    }
                    publish(&graph, &tx);
                }
                if let Some(completion) = pending.borrow_mut().remove(&seq.raw()) {
                    // Callers also wait for the observed properties after this barrier.
                    let _ = completion.reply.send(Ok(()));
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
        let core = core.downgrade();
        let route_syncs = route_syncs.clone();
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
                        graph_added
                            .borrow_mut()
                            .metadata_ids
                            .insert(name.clone(), id);
                        graph_added
                            .borrow_mut()
                            .metadata
                            .insert(name.clone(), BTreeMap::new());
                        let listener = metadata
                            .add_listener_local()
                            .property(move |subject, key, type_, value| {
                                {
                                    let mut graph = g.borrow_mut();
                                    if graph.metadata_ids.get(&n) != Some(&id) {
                                        return 0;
                                    }
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
                                metadata,
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
                                ..Device::default()
                            },
                        );
                        let g = graph_added.clone();
                        let t = tx_added.clone();
                        let p = Rc::downgrade(&proxies_added);
                        let c = core.upgrade().unwrap().downgrade();
                        let completions = route_syncs.clone();
                        let listener = device
                            .add_listener_local()
                            .info(move |info| {
                                if let Some(device) = g.borrow_mut().devices.get_mut(&id) {
                                    device.properties.extend(copy_props(info.props()));
                                }
                                let Some(proxies) = p.upgrade() else {
                                    return;
                                };
                                if let Some(device) = proxies.borrow_mut().devices.get_mut(&id) {
                                    // Remote devices announce parameter changes through info.
                                    for param in info.params() {
                                        let param_id = param.id().as_raw();
                                        let flags = param.flags().bits();
                                        if device.param_flags.insert(param_id, flags) == Some(flags)
                                        {
                                            continue;
                                        }
                                        if param.id() == spa::param::ParamType::Profile {
                                            if let Some(snapshot) =
                                                g.borrow_mut().devices.get_mut(&id)
                                            {
                                                snapshot.revision += 1;
                                            }
                                        } else if param.id() == spa::param::ParamType::Route {
                                            device.route_dirty = true;
                                            device.route_readable =
                                                flags & spa::sys::SPA_PARAM_INFO_READ != 0;
                                        }
                                    }
                                }
                                if info
                                    .change_mask()
                                    .contains(pw::device::DeviceChangeMask::PARAMS)
                                    && !info
                                        .params()
                                        .iter()
                                        .any(|p| p.id() == spa::param::ParamType::Route)
                                {
                                    if let Some(device) = proxies.borrow_mut().devices.get_mut(&id)
                                    {
                                        if device
                                            .param_flags
                                            .remove(&spa::param::ParamType::Route.as_raw())
                                            .is_some()
                                        {
                                            device.route_dirty = true;
                                            device.route_readable = false;
                                        }
                                    }
                                }
                                if let Some(core) = c.upgrade() {
                                    refresh_routes(id, &proxies, &g, &core, &completions);
                                }
                                publish(&g, &t);
                            })
                            .param({
                                let p = Rc::downgrade(&proxies_added);
                                move |_, param, index, _, pod| {
                                    if param != spa::param::ParamType::Route {
                                        return;
                                    }
                                    let Some(proxies) = p.upgrade() else {
                                        return;
                                    };
                                    if let Some(device) = proxies.borrow_mut().devices.get_mut(&id)
                                    {
                                        if let Some(route) = pod.and_then(read_route) {
                                            device.route_params.insert(index, route);
                                        }
                                    }
                                }
                            })
                            .register();
                        proxies_added.borrow_mut().devices.insert(
                            id,
                            OwnedDevice {
                                _listener: listener,
                                device,
                                param_flags: BTreeMap::new(),
                                route_params: BTreeMap::new(),
                                route_dirty: false,
                                route_readable: false,
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
                        if graph.metadata_ids.get(&metadata.name) == Some(&id) {
                            graph.metadata.remove(&metadata.name);
                            graph.metadata_ids.remove(&metadata.name);
                        }
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
            Message::Metadata(command) => {
                let result = command
                    .batch
                    .apply(&graph.borrow(), &proxies.borrow())
                    .and_then(|()| {
                        core.upgrade()
                            .ok_or_else(|| Failure::unknown("Audio server disconnected"))?
                            .sync(0)
                            .map_err(|_| Failure::unknown("Audio server disconnected"))
                    });
                match result {
                    Ok(seq) => {
                        pending.borrow_mut().insert(seq.raw(), command.completion);
                    }
                    Err(error) => {
                        let _ = command.completion.reply.send(Err(error));
                    }
                }
            }
            Message::Patch(command) => {
                let result = (|| {
                    validate_identity(&graph.borrow(), &command.identity)?;
                    validate_patch(&command.patch)?;
                    let graph = graph.borrow();
                    let node = validate_identity(&graph, &command.identity)?;
                    if node
                        .properties
                        .get("device.id")
                        .and_then(|id| id.parse::<u32>().ok())
                        .and_then(|id| graph.devices.get(&id))
                        .is_some_and(|device| device.route_request.is_some())
                    {
                        return Err(Failure::new("busy", "Audio route is updating"));
                    }
                    let route = route_for(&graph, node);
                    let data = patch_pod(&command.patch, route.map(|(_, route)| route))?;
                    let pod = spa::pod::Pod::from_bytes(&data).ok_or_else(|| {
                        Failure::new("encoding_error", "Invalid audio properties")
                    })?;
                    let proxies = proxies.borrow();
                    if let Some((device_id, _)) = route {
                        let device = proxies.devices.get(&device_id).ok_or_else(|| {
                            Failure::new("stale_node", "Audio device disappeared")
                        })?;
                        device
                            .device
                            .set_param(spa::param::ParamType::Route, 0, pod);
                    } else {
                        let node = proxies
                            .nodes
                            .get(&command.identity.id)
                            .ok_or_else(|| Failure::new("stale_node", "Audio node disappeared"))?;
                        node.node.set_param(spa::param::ParamType::Props, 0, pod);
                    }
                    core.upgrade()
                        .ok_or_else(|| Failure::unknown("Audio server disconnected"))?
                        .sync(0)
                        .map_err(|_| Failure::unknown("Audio server disconnected"))
                })();
                match result {
                    Ok(seq) => {
                        pending.borrow_mut().insert(seq.raw(), command.completion);
                    }
                    Err(error) => {
                        let _ = command.completion.reply.send(Err(error));
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
        let bytes = patch_pod(&patch, None).unwrap();
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
