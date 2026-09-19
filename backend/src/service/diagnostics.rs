//! On-demand diagnostic samples shared across windows, outside audio transactions.
use super::{NoParams, Service};
use crate::protocol::{Failure, Request, Result};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

pub(super) struct Sample {
    finished: Instant,
    result: Result<()>,
}

impl Service {
    pub(super) async fn refresh_diagnostics(&self, request: &Request) -> Result<Value> {
        request.params::<NoParams>()?;
        // A separate lock coalesces concurrent readers without holding the
        // audio mutation queue during slow service or graph inspection.
        let mut sample = self.diagnostics.lock().await;
        if let Some(sample) = sample.as_ref() {
            if sample.finished.elapsed() < Duration::from_secs(5) {
                return sample.result.clone().map(|()| json!({"cached": true}));
            }
        }
        self.update_state(|state| {
            if !state["diagnostics"].is_object() {
                state["diagnostics"] = json!({"revision": "0"});
            }
            state["diagnostics"]["refreshing"] = json!(true);
        });
        let snapshot = match &self.native {
            Some(native) => crate::diagnostics::collect(native).await,
            None => Err(Failure::new(
                "diagnostics_failed",
                "The audio graph is unavailable",
            )),
        };
        let result = snapshot.as_ref().map(|_| ()).map_err(Clone::clone);
        self.update_state(|state| {
            let report = &mut state["diagnostics"];
            let revision = report["revision"]
                .as_str()
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(0)
                + 1;
            report["revision"] = json!(revision.to_string());
            report["refreshing"] = json!(false);
            match snapshot {
                Ok(snapshot) => {
                    report["snapshot"] = snapshot;
                    report["error"] = json!("");
                }
                Err(error) => report["error"] = json!(error.message),
            }
        });
        *sample = Some(Sample {
            finished: Instant::now(),
            result: result.clone(),
        });
        // The report travels in the existing bounded snapshot chunks, keeping
        // large device/route lists out of single-frame command replies.
        result.map(|()| json!({"cached": false}))
    }
    pub(super) async fn copy_diagnostics(&self, request: &Request) -> Result<Value> {
        request.params::<NoParams>()?;
        self.refresh_diagnostics(request).await?;
        let snapshot = self.state.borrow()["diagnostics"]["snapshot"].clone();
        crate::diagnostics::copy(&snapshot).await?;
        Ok(json!({"copied":true}))
    }
}
