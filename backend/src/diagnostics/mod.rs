//! On-demand inspection. Reuse the observed graph; bound every external sample.
mod report;
mod topology;
pub use report::support_report;

use crate::{
    native::{self, Graph},
    protocol::{Failure, Result},
    pulse,
    routing::{self, Direction},
    storage,
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, os::unix::fs::PermissionsExt, process::Stdio, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::Command,
};

pub async fn collect(native: &native::Handle) -> Result<Value> {
    let graph = native.snapshot();
    if !graph.ready {
        return Err(Failure::new(
            "diagnostics_failed",
            "The audio graph is unavailable",
        ));
    }
    let devices_graph = graph.clone();
    let devices = tokio::task::spawn_blocking(move || endpoints(&devices_graph));
    let (top, units, version, devices) = tokio::join!(
        capture("pw-top", &["-b", "-n", "1"], 1_048_576),
        capture(
            "systemctl",
            &[
                "--user",
                "show",
                "pipewire.service",
                "wireplumber.service",
                "pipewire-pulse.service",
                "--property=Id,LoadState,ActiveState,SubState,NRestarts",
                "--no-pager"
            ],
            65_536
        ),
        capture("wireplumber", &["--version"], 4096),
        devices,
    );
    let current = native.snapshot();
    if !current.ready || current.generation != graph.generation {
        return Err(Failure::new(
            "diagnostics_failed",
            "The audio graph changed during collection",
        ));
    }
    let mut warnings = Vec::new();
    let stats = top.as_ref().ok().and_then(|text| statistics(text, &graph));
    if stats.is_none() {
        warnings.push("Live PipeWire processing statistics could not be read.");
    }
    let services = services(units.as_deref().unwrap_or(""));
    let services_ok = services.iter().all(|s| s["active"] == true);
    if !services_ok {
        warnings.push("One or more audio services are not running normally.");
    }
    let (devices, endpoints_ok) = match devices {
        Ok(Ok(devices)) => (devices, true),
        _ => {
            warnings.push("Audio device formats could not be inspected.");
            (Vec::new(), false)
        }
    };
    let output = routing::default_name(&graph, Direction::Playback).unwrap_or_default();
    let mut input = routing::default_name(&graph, Direction::Recording).unwrap_or_default();
    if !graph
        .nodes
        .values()
        .any(|n| n.name == input && routing::endpoint_direction(n) == Some(Direction::Recording))
    {
        input.clear();
    }
    if output.is_empty() {
        warnings.push("No default playback device is currently available.");
    }
    let stats_ok = stats.is_some();
    let stats = stats.unwrap_or_default();
    if stats.errors > 0 {
        warnings.push("PipeWire reported XRUNs or processing errors.");
    }
    let setting = |key| {
        native::metadata::value(&graph, "settings", key)
            .and_then(|v| v.value.parse::<u32>().ok())
            .unwrap_or(0)
    };
    let rate = if stats.rate > 0 {
        stats.rate
    } else {
        setting("clock.rate")
    };
    let quantum = if stats.rate > 0 {
        stats.quantum
    } else {
        setting("clock.quantum")
    };
    let manifest: Value =
        serde_json::from_str(include_str!("../../../packaging/manifest.json")).unwrap();
    let snapshot = json!({
        "version":1, "generatedAt":timestamp(),
        "healthy": services_ok && endpoints_ok && !output.is_empty() && stats.errors == 0 && stats_ok,
        "versions":{"plugin":manifest["version"], "pipewire":graph.version, "wireplumber": version.ok().map(|s| version_number(&s)).unwrap_or_default()},
        "graph":{"available":true, "active":stats.active > 0, "source":if stats.rate > 0 {"active"} else {"configured"},
            "rate":rate, "quantum":quantum, "latencyMs":if rate > 0 {(f64::from(quantum)*10000.0/f64::from(rate)).round()/10.0} else {0.0},
            "loadPercent":stats.load, "errors":stats.errors, "activeNodes":stats.active},
        "defaults":{"output":output,"input":input}, "services":services, "devices":devices,
        "routes":topology::routes(&graph), "warnings":warnings,
        "capabilities":{"speakerTest":!output.is_empty() && executable("speaker-test"), "supportReport":true,
            "clipboard":executable("wl-copy"), "recovery":executable("omarchy-restart-audio") && executable("omarchy-launch-floating-terminal-with-presentation"), "topology":true}
    });
    if crate::protocol::encode(&snapshot)?.len() > crate::protocol::MAX_SNAPSHOT_BYTES / 4 {
        return Err(Failure::new(
            "diagnostics_too_large",
            "The diagnostics report is too large to display",
        ));
    }
    Ok(snapshot)
}

async fn capture(program: &str, args: &[&str], limit: usize) -> Result<String> {
    let mut command = Command::new(program);
    command
        .args(args)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    run(command, None, limit).await
}

pub async fn copy(snapshot: &Value) -> Result<()> {
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .unwrap_or_default();
    let host = std::fs::read_to_string("/proc/sys/kernel/hostname").unwrap_or_default();
    let report = support_report(snapshot, &user, host.trim());
    let mut command = Command::new("wl-copy");
    command
        .args(["--type", "text/plain"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    run(command, Some(report.as_bytes()), 0).await.map(|_| ())
}

async fn run(mut command: Command, input: Option<&[u8]>, limit: usize) -> Result<String> {
    command.kill_on_drop(true).process_group(0);
    let mut child = command.spawn().map_err(|_| sample_failed())?;
    let stdout = child.stdout.take();
    let stdin = child.stdin.take();
    let work = async {
        let mut bytes = Vec::new();
        if let Some(mut stdin) = stdin {
            stdin.write_all(input.unwrap_or_default()).await?;
            stdin.shutdown().await?;
        }
        if let Some(stdout) = stdout {
            stdout
                .take(limit as u64 + 1)
                .read_to_end(&mut bytes)
                .await?;
        }
        if bytes.len() > limit {
            return Err(std::io::Error::other("Diagnostic sample is too large"));
        }
        let status = child.wait().await?;
        if !status.success() {
            return Err(std::io::Error::other("Diagnostic sample failed"));
        }
        String::from_utf8(bytes).map_err(std::io::Error::other)
    };
    match tokio::time::timeout(Duration::from_secs(3), work).await {
        Ok(Ok(text)) => Ok(text),
        _ => {
            // SAFETY: this is our unreaped child's process group.
            if let Some(pid) = child.id() {
                unsafe {
                    libc::kill(-(pid as i32), libc::SIGKILL);
                }
            }
            let _ = child.wait().await;
            Err(sample_failed())
        }
    }
}
fn sample_failed() -> Failure {
    Failure::new(
        "diagnostics_failed",
        "Could not complete the diagnostic action",
    )
}
fn executable(name: &str) -> bool {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).any(|p| {
        p.join(name)
            .metadata()
            .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    })
}

fn endpoints(graph: &Graph) -> Result<Vec<Value>> {
    let mut session = pulse::Session::connect()?;
    let mut devices = Vec::new();
    // Sink and source bindings expose the same format fields but distinct types.
    macro_rules! endpoint {
        ($info:expr, $direction:expr, $default:expr) => {{
            let info = $info;
            let name = info.name.as_deref().unwrap_or("");
            if !storage::identifier(&json!(name), 160).is_empty() {
                let property = |keys: &[&str], limit| clean(&keys.iter().find_map(|key| info.proplist.get_str(key)).unwrap_or_default(), limit);
                devices.push(json!({"direction":$direction, "name":name,
                    "label":clean(info.description.as_deref().unwrap_or(name),160), "state":format!("{:?}",info.state).to_ascii_lowercase(),
                    "format":info.sample_spec.print().to_string(), "channelMap":info.channel_map.print().to_string(), "channels":info.sample_spec.channels,
                    "port":clean(info.active_port.as_ref().and_then(|p| p.description.as_deref().or(p.name.as_deref())).unwrap_or(""),160),
                    "profile":property(&["device.profile.description", "device.profile.name"],160),
                    "codec":property(&["bluetooth.codec", "api.bluez5.codec", "bluez5.codec"],64),
                    "bluetooth":info.proplist.get_str("device.bus").as_deref() == Some("bluetooth") || name.starts_with("bluez_"),
                    "default":Some(name) == $default.as_deref()}));
            }
        }};
    }
    let output = routing::default_name(graph, Direction::Playback);
    let input = routing::default_name(graph, Direction::Recording);
    for info in session.sinks()?.iter().take(64) {
        endpoint!(info, "output", output);
    }
    for info in session
        .sources()?
        .iter()
        .filter(|s| {
            s.monitor_of_sink.is_none()
                && s.proplist.get_str("device.class").as_deref() != Some("monitor")
        })
        .take(64)
    {
        endpoint!(info, "input", input);
    }
    devices.sort_by_key(|d| {
        (
            d["direction"].as_str().unwrap().to_owned(),
            d["default"] != true,
            d["label"].as_str().unwrap().to_ascii_lowercase(),
        )
    });
    Ok(devices)
}

fn clean(text: &str, limit: usize) -> String {
    storage::label(&json!(text), limit)
}
fn version_number(text: &str) -> String {
    text.split(|c: char| !c.is_ascii_digit() && c != '.')
        .find(|v| v.contains('.') && v.len() <= 32 && v.split('.').all(|n| !n.is_empty()))
        .unwrap_or("")
        .into()
}
fn timestamp() -> String {
    // SAFETY: both C functions write only to the initialized, correctly sized buffers.
    unsafe {
        let time = libc::time(std::ptr::null_mut());
        let mut tm = std::mem::zeroed();
        let mut buffer = [0u8; 32];
        if libc::gmtime_r(&time, &mut tm).is_null() {
            return String::new();
        }
        let size = libc::strftime(
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            c"%Y-%m-%dT%H:%M:%SZ".as_ptr(),
            &tm,
        );
        String::from_utf8_lossy(&buffer[..size]).into_owned()
    }
}

fn services(text: &str) -> Vec<Value> {
    let units: BTreeMap<_, _> = text
        .split("\n\n")
        .filter_map(|block| {
            let fields: BTreeMap<_, _> = block
                .lines()
                .filter_map(|line| line.split_once('='))
                .collect();
            Some((*fields.get("Id")?, fields))
        })
        .collect();
    [("pipewire.service","PipeWire"), ("wireplumber.service","WirePlumber"), ("pipewire-pulse.service","PipeWire Pulse")].iter().map(|(name,label)| {
        let get = |key| clean(units.get(name).and_then(|unit| unit.get(key)).unwrap_or(&"unknown"),32);
        let active = get("ActiveState"); let sub = get("SubState");
        json!({"name":name, "label":label, "loadState":get("LoadState"), "activeState":active,"subState":sub,
            "active":active == "active" && sub == "running", "restarts":get("NRestarts").parse::<u32>().ok().filter(|n| *n <= 1_000_000).unwrap_or(0)})
    }).collect()
}

struct Stats {
    rate: u32,
    quantum: u32,
    active: u32,
    load: f64,
    errors: u64,
}
impl Default for Stats {
    fn default() -> Self {
        Self {
            rate: 0,
            quantum: 0,
            active: 0,
            load: -1.0,
            errors: 0,
        }
    }
}
fn statistics(text: &str, graph: &Graph) -> Option<Stats> {
    let mut stats = Stats::default();
    let mut header = false;
    for line in text.lines() {
        let fields: Vec<_> = line.split_ascii_whitespace().take(10).collect();
        if fields.get(1) == Some(&"ID") && fields.get(7) == Some(&"B/Q") {
            header = true;
            continue;
        }
        if !header || fields.len() < 9 {
            continue;
        }
        let Some(node) = fields[1]
            .parse::<u32>()
            .ok()
            .and_then(|id| graph.nodes.get(&id))
        else {
            continue;
        };
        if !node
            .properties
            .get("media.class")
            .is_some_and(|v| v.contains("Audio"))
        {
            continue;
        }
        if matches!(fields[0], "R" | "r" | "T" | "t") {
            stats.active += 1;
            if stats.rate == 0 {
                let rate = fields[3].parse::<u32>().ok().filter(|r| *r > 0);
                let quantum = fields[2].parse::<u32>().ok().filter(|q| *q > 0);
                if let (Some(rate), Some(quantum)) = (rate, quantum) {
                    stats.rate = rate;
                    stats.quantum = quantum;
                }
            }
        }
        if let Ok(load) = fields[7].parse::<f64>() {
            if load.is_finite() && load >= 0.0 {
                stats.load = stats.load.max((load * 10000.0).round() / 100.0);
            }
        }
        stats.errors = stats
            .errors
            .saturating_add(fields[8].parse::<u64>().unwrap_or(0));
    }
    header.then_some(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn statistics_use_processing_time_and_ignore_foreign_nodes() {
        let mut graph = Graph::default();
        graph.nodes.insert(
            40,
            native::Node {
                properties: BTreeMap::from([("media.class".into(), "Audio/Sink".into())]),
                ..Default::default()
            },
        );
        let text = include_str!("../../../test/fixtures/diagnostics/pw-top.txt");
        let stats = statistics(text, &graph).unwrap();
        assert_eq!(
            (stats.rate, stats.quantum, stats.active, stats.errors),
            (48000, 256, 1, 2)
        );
        assert_eq!(stats.load, 3.0);
        assert!(statistics("invalid", &graph).is_none());
    }
    #[test]
    fn missing_services_are_never_healthy() {
        assert!(services("").iter().all(|s| s["active"] == false));
        let result = services(
            "Id=pipewire.service\nActiveState=active\nSubState=running\nLoadState=loaded\nNRestarts=2\n",
        );
        assert_eq!(result[0]["active"], true);
        assert_eq!(result[0]["restarts"], 2);
        assert_eq!(result[1]["active"], false);
    }
}
