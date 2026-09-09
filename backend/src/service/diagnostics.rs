//! On-demand diagnostic samples shared across windows, outside audio transactions.
use super::{NoParams, Service};
use crate::adapter::Call;
use crate::protocol::{self, Failure, Request, Result};
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
        // native/helper mutation queue during slow service or graph inspection.
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
        let snapshot = self
            .adapter
            .run(
                &Call::new("audio-diagnostics", vec!["snapshot".into()]),
                None,
            )
            .await
            .map_err(|_| Failure::new("diagnostics_failed", "Could not collect audio diagnostics"))
            .and_then(|output| {
                if output.exit_code != 0 {
                    return Err(Failure::new(
                        "diagnostics_failed",
                        "Could not collect audio diagnostics",
                    ));
                }
                parse_snapshot(&output.stdout)
            });
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
}

fn parse_snapshot(raw: &str) -> Result<Value> {
    let invalid = || Failure::new("invalid_diagnostics", "Could not read audio diagnostics");
    let mut snapshot: Value = serde_json::from_str(raw).map_err(|_| invalid())?;
    if !snapshot.is_object()
        || snapshot["version"] != 1
        || !snapshot["graph"].is_object()
        || ["services", "devices", "routes", "warnings"]
            .iter()
            .any(|key| !snapshot[key].is_array())
    {
        return Err(invalid());
    }
    // Embedded helpers no longer have a checkout-relative manifest. Report
    // the version compiled with this service, including while an update drains.
    let manifest: Value = serde_json::from_str(include_str!("../../../packaging/manifest.json"))
        .map_err(|_| invalid())?;
    if !snapshot["versions"].is_object() {
        snapshot["versions"] = json!({});
    }
    snapshot["versions"]["plugin"] = manifest["version"].clone();
    // Reserve most of the shared snapshot budget for the live graph. Reject a
    // pathological report without breaking the control subscription.
    if protocol::encode(&snapshot)?.len() > protocol::MAX_SNAPSHOT_BYTES / 4 {
        return Err(Failure::new(
            "diagnostics_too_large",
            "The diagnostics report is too large to display",
        ));
    }
    Ok(snapshot)
}
