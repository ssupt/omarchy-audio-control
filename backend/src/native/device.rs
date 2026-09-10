//! Enumerate related device parameters as one batch and publish at a core barrier.
use super::{Device, Graph, Proxies, audio, catalog, copy_props};
use pipewire::{self as pw, spa};
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    rc::Rc,
    sync::Arc,
};

const PARAMS: [u32; 4] = [
    spa::sys::SPA_PARAM_EnumProfile,
    spa::sys::SPA_PARAM_Profile,
    spa::sys::SPA_PARAM_EnumRoute,
    spa::sys::SPA_PARAM_Route,
];

pub(super) struct OwnedDevice {
    _listener: pw::device::DeviceListener,
    pub device: pw::device::Device,
    flags: BTreeMap<u32, u32>,
    dirty: BTreeSet<u32>,
    inflight: BTreeSet<u32>,
    routes: BTreeMap<u32, audio::Route>,
    catalog: catalog::Catalog,
}
impl OwnedDevice {
    pub fn new(device: pw::device::Device, listener: pw::device::DeviceListener) -> Self {
        Self {
            _listener: listener,
            device,
            flags: BTreeMap::new(),
            dirty: BTreeSet::new(),
            inflight: BTreeSet::new(),
            routes: BTreeMap::new(),
            catalog: catalog::Catalog::default(),
        }
    }
    pub fn info(&mut self, snapshot: &mut Device, info: &pw::device::DeviceInfoRef) {
        snapshot.properties.extend(copy_props(info.props()));
        if info
            .change_mask()
            .contains(pw::device::DeviceChangeMask::PARAMS)
        {
            for id in PARAMS {
                let flags = info
                    .params()
                    .iter()
                    .find(|p| p.id().as_raw() == id)
                    .map(|p| p.flags().bits());
                if self.flags.get(&id).copied() != flags {
                    match flags {
                        Some(flags) => {
                            self.flags.insert(id, flags);
                        }
                        None => {
                            self.flags.remove(&id);
                        }
                    }
                    self.dirty.insert(id);
                    if id != spa::sys::SPA_PARAM_Route {
                        snapshot.catalog_ready = false;
                    }
                }
            }
        }
        if self.dirty.is_empty() && self.inflight.is_empty() {
            snapshot.catalog_ready = true;
        }
    }
    pub fn param(&mut self, param: u32, index: u32, pod: Option<&spa::pod::Pod>) {
        if !self.inflight.contains(&param) || index >= 256 {
            return;
        }
        if let Some(object) = pod.and_then(catalog::object) {
            self.catalog.read(param, index, &object);
            if param == spa::sys::SPA_PARAM_Route {
                if let Some(route) = audio::read_route(object) {
                    self.routes.insert(index, route);
                }
            }
        }
    }

    pub fn commit(&mut self, snapshot: &mut Device) {
        snapshot.param_request = None;
        if !self.dirty.is_empty() {
            // A profile/port change may invalidate every part of this batch.
            self.dirty.append(&mut self.inflight);
            return;
        }
        let mut changed = false;
        for param in std::mem::take(&mut self.inflight) {
            if snapshot.catalog.differs(&self.catalog, param) {
                Arc::make_mut(&mut snapshot.catalog).take(&mut self.catalog, param);
                changed = true;
            } else {
                self.catalog.clear(param);
            }
            if param == spa::sys::SPA_PARAM_Route {
                snapshot.routes = std::mem::take(&mut self.routes);
            }
        }
        if changed {
            snapshot.revision += 1;
        }
        snapshot.catalog_ready = true;
    }
}

pub(super) fn refresh(
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
    if device.dirty.is_empty() || snapshot.param_request.is_some() {
        return;
    }
    device.inflight = std::mem::take(&mut device.dirty);
    for &param in &device.inflight {
        device.catalog.clear(param);
        if param == spa::sys::SPA_PARAM_Route {
            device.routes.clear();
        }
        if device
            .flags
            .get(&param)
            .is_some_and(|f| f & spa::sys::SPA_PARAM_INFO_READ != 0)
        {
            device
                .device
                .enum_params(0, Some(spa::param::ParamType::from_raw(param)), 0, 256);
        }
    }
    if let Ok(done) = core.sync(0) {
        snapshot.param_request = Some(done.raw());
        syncs.borrow_mut().insert(done.raw(), id);
    }
}
