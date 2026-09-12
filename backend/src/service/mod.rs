//! Shared coordinator: lifecycle, operation admission and protocol dispatch.
mod adapters;
mod audio;
mod automation;
mod diagnostics;
mod microphone;
mod policy;
mod state;

use crate::adapter::Adapter;
use crate::native;
use crate::protocol::{Failure, MAX_FRAME_BYTES, MAX_SNAPSHOT_BYTES, Request, Result};
use crate::storage::Storage;
use crate::{PROTOCOL_VERSION, SERVICE_NAME};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::watch;

const MAX_OPERATIONS: u32 = 32;

/// Shared by all UI/CLI connections. Domain state and transaction ownership
/// belong here, never in a connection handler or one of the QML surfaces.
pub struct Service {
    epoch: String,
    state: watch::Sender<Arc<Value>>,
    native: Option<native::Handle>,
    mutation: Arc<tokio::sync::Mutex<()>>,
    storage: Option<Storage>,
    adapter: Adapter,
    operations: Arc<tokio::sync::Semaphore>,
    users: watch::Sender<usize>,
    microphone: tokio::sync::Mutex<microphone::Session>,
    diagnostics: tokio::sync::Mutex<Option<diagnostics::Sample>>,
    catalog: std::sync::Mutex<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NoParams {}

impl Service {
    pub fn new() -> std::io::Result<Arc<Self>> {
        Self::create(None, None)
    }

    pub fn start() -> std::io::Result<Arc<Self>> {
        let native = native::Handle::start()?;
        let mut graph = native.subscribe();
        let storage = Storage::from_environment().map_err(std::io::Error::other)?;
        let service = Self::create(Some(native), Some(storage))?;
        service.watch_stores();
        service.start_automation();
        let weak = Arc::downgrade(&service);
        tokio::spawn(async move {
            while graph.changed().await.is_ok() {
                let snapshot = graph.borrow_and_update().clone();
                let Some(service) = weak.upgrade() else {
                    break;
                };
                service.publish_graph(&snapshot);
            }
        });
        Ok(service)
    }

    fn create(
        native: Option<native::Handle>,
        storage: Option<Storage>,
    ) -> std::io::Result<Arc<Self>> {
        let epoch = std::fs::read_to_string("/proc/sys/kernel/random/uuid")?
            .trim()
            .to_owned();
        let (state, _) = watch::channel(Arc::new(json!({
            "epoch": epoch, "revision": "0", "connected": false,
            "nodes": [], "busy": false
        })));
        Ok(Arc::new(Self {
            epoch,
            state,
            native,
            mutation: Arc::new(tokio::sync::Mutex::new(())),
            storage,
            adapter: Adapter::from_environment().map_err(std::io::Error::other)?,
            operations: Arc::new(tokio::sync::Semaphore::new(MAX_OPERATIONS as usize)),
            users: watch::channel(0).0,
            microphone: tokio::sync::Mutex::new(microphone::Session::default()),
            diagnostics: tokio::sync::Mutex::new(None),
            catalog: std::sync::Mutex::new(String::new()),
        }))
    }

    pub fn subscribe(&self) -> watch::Receiver<Arc<Value>> {
        self.state.subscribe()
    }

    pub fn lease(self: &Arc<Self>) -> Lease {
        self.users.send_modify(|users| *users += 1);
        Lease(Arc::downgrade(self))
    }

    /// Admitted work outlives its connection so verification and rollback can finish.
    pub fn dispatch(
        self: Arc<Self>,
        request: Request,
    ) -> Result<tokio::task::JoinHandle<Result<Value>>> {
        let permit = self
            .operations
            .clone()
            .try_acquire_owned()
            .map_err(|_| Failure::new("busy", "Audio operation queue is full"))?;
        Ok(tokio::spawn(async move {
            let _permit = permit;
            self.handle(&request).await
        }))
    }

    pub async fn drain(&self) {
        self.stop_microphone(None, true).await;
        // The listener is closed before this barrier, so no new work can arrive.
        let _ = self.operations.acquire_many(MAX_OPERATIONS).await;
        let _transaction = self.mutation.lock().await;
    }

    async fn transaction(&self) -> Result<tokio::sync::MutexGuard<'_, ()>> {
        tokio::time::timeout(std::time::Duration::from_secs(5), self.mutation.lock())
            .await
            .map_err(|_| {
                Failure::new(
                    "busy",
                    "Another audio operation is still finishing; no change was started",
                )
            })
    }

    fn set_busy_for(&self, busy: bool, operation: &str) {
        self.update_state(|state| {
            state["busy"] = json!(busy);
            state["operation"] = json!(if busy { operation } else { "" });
        });
    }

    fn set_busy(&self, busy: bool) {
        self.set_busy_for(busy, "transaction");
    }

    pub async fn handle(self: &Arc<Self>, request: &Request) -> Result<Value> {
        match request.method.as_str() {
            "hello" => {
                request.params::<NoParams>()?;
                Ok(json!({
                    "name": SERVICE_NAME, "version": env!("CARGO_PKG_VERSION"),
                    "protocolVersion": PROTOCOL_VERSION, "epoch": self.epoch,
                    "buildId": crate::launch::BUILD_ID, "pid": std::process::id(),
                    "transport": "jsonl-ascii",
                    "capabilities": [
                        "health", "state.subscribe", "node.audio", "node.level",
                        "store.read", "settings.set", "preferences.default", "preferences.profile",
                        "rules.set_app", "rules.delete_app", "devices.alias", "devices.flag",
                        "scenes.save", "scenes.delete", "adapter.run", "scene.apply", "scene.capture",
                        "microphone.start", "microphone.stop", "diagnostics.refresh", "policy.set", "port.set", "profile.set"
                    ],
                    "maxFrameBytes": MAX_FRAME_BYTES, "maxSnapshotBytes": MAX_SNAPSHOT_BYTES
                }))
            }
            "health" => {
                request.params::<NoParams>()?;
                Ok(json!({"status": "ok", "audioConnected": self.state.borrow()["connected"]}))
            }
            "state.subscribe" => {
                request.params::<NoParams>()?;
                Ok(json!({"subscribed": true, "epoch": self.epoch}))
            }
            "node.audio" | "node.level" => self.audio_request(request).await,
            "microphone.start" => self.start_microphone(request).await,
            "microphone.stop" => self.stop_microphone_request(request).await,
            "profile.set" => self.profile_request(request).await,
            "port.set" => self.port_request(request).await,
            "policy.set" => self.policy_request(request).await,
            "diagnostics.refresh" => self.refresh_diagnostics(request).await,
            "scene.apply" | "scene.capture" => self.scene_request(request).await,
            "adapter.run" => self.adapter_request(request).await,
            "store.read"
            | "settings.set"
            | "preferences.default"
            | "preferences.profile"
            | "rules.set_app"
            | "rules.delete_app"
            | "devices.alias"
            | "devices.flag"
            | "scenes.save"
            | "scenes.delete" => self.store_request(request).await,
            _ => Err(Failure::new("method_not_found", "Unknown control method")),
        }
    }
}

struct Busy<'a>(&'a Service);
impl Drop for Busy<'_> {
    fn drop(&mut self) {
        self.0.set_busy(false);
    }
}

/// Dropping the shell subscription withdraws its automatic-operation lease.
pub struct Lease(std::sync::Weak<Service>);
impl Drop for Lease {
    fn drop(&mut self) {
        if let Some(service) = self.0.upgrade() {
            service
                .users
                .send_modify(|users| *users = users.saturating_sub(1));
            if *service.users.borrow() == 0 {
                tokio::spawn(async move {
                    service.stop_microphone(None, true).await;
                });
            }
        }
    }
}
