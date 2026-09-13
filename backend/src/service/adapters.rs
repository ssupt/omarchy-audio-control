//! Compatibility helpers for the remaining migration boundaries.
use super::{Busy, Service};
use crate::adapter::Call;
use crate::files::FileLock;
use crate::protocol::{Failure, Request, Result};
use serde_json::Value;

impl Service {
    pub(super) async fn adapter_request(&self, request: &Request) -> Result<Value> {
        let call = request.params::<Call>()?;
        call.validate()?;
        if call.helper == "audio-diagnostics" {
            return Err(Failure::new(
                "invalid_params",
                "Use diagnostics.refresh to collect a shared report",
            ));
        }
        let _transaction = self.transaction().await?;
        if call.mutating() {
            let graph = self.native.as_ref().map(|native| native.snapshot());
            if graph.as_ref().is_none_or(|g| {
                !g.ready || call.generation.is_empty() || g.generation != call.generation
            }) {
                return Err(Failure::new(
                    "stale_graph",
                    "Audio graph changed before this operation started",
                ));
            }
        }
        let lock = if call.mutating() {
            Some(FileLock::mutation().await?)
        } else {
            None
        };
        self.set_busy(call.mutating());
        let _busy = Busy(self);
        let output = self.adapter.run(&call, lock.as_ref()).await?;
        if call.mutating() {
            self.reload_stores().await?;
        }
        Ok(serde_json::to_value(output).unwrap())
    }
}
