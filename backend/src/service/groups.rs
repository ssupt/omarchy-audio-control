use super::{Busy, Service};
use crate::protocol::{Failure, Request, Result};
use crate::{
    files::FileLock,
    groups::{self, Change},
};
use serde_json::Value;

impl Service {
    pub(super) async fn group_request(&self, request: &Request) -> Result<Value> {
        let change = match request.method.as_str() {
            "groups.create" => Change::Create(request.params()?),
            "groups.update" => Change::Update(request.params()?),
            "groups.delete" => Change::Delete(request.params()?),
            _ => {
                return Err(Failure::new(
                    "method_not_found",
                    "Unknown output group operation",
                ));
            }
        };
        let _transaction = self.transaction().await?;
        let _external = FileLock::mutation().await?;
        self.set_busy_for(true, &request.method);
        let _busy = Busy(self);
        let result = self.change_groups(change).await;
        self.reload_stores().await?;
        result
    }
    pub(super) async fn change_groups(&self, change: Change) -> Result<Value> {
        let native = self
            .native
            .clone()
            .ok_or_else(|| Failure::new("disconnected", "Native audio is unavailable"))?;
        let storage = self
            .storage
            .clone()
            .ok_or_else(|| Failure::new("configuration_error", "Audio rules are unavailable"))?;
        tokio::task::spawn_blocking(move || groups::apply(&native, &storage, change))
            .await
            .map_err(|_| Failure::unknown("Output group verification did not finish"))?
    }
}
