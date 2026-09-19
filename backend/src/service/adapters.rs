//! Read-only compatibility queries for upstream Omarchy output filtering.
use super::Service;
use crate::adapter::Call;
use crate::protocol::{Request, Result};
use serde_json::Value;

impl Service {
    pub(super) async fn adapter_request(&self, request: &Request) -> Result<Value> {
        let call = request.params::<Call>()?;
        call.validate()?;
        Ok(serde_json::to_value(self.adapter.run(&call).await?).unwrap())
    }
}
