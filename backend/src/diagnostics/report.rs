//! Export selected fields only. Never include node names, media titles or logs.
use serde_json::Value;
use std::fmt::Write;

pub fn support_report(snapshot: &Value, user: &str, host: &str) -> String {
    let safe = |value: &Value| redact(value.as_str().unwrap_or("unknown"), user, host);
    let mut text = String::from("Advanced Audio Control support report\n");
    let _ = writeln!(
        text,
        "Generated: {}\n\nVersions",
        safe(&snapshot["generatedAt"])
    );
    for (key, label) in [
        ("plugin", "Advanced Audio Control"),
        ("pipewire", "PipeWire"),
        ("wireplumber", "WirePlumber"),
    ] {
        let _ = writeln!(text, "  {label}: {}", safe(&snapshot["versions"][key]));
    }
    let graph = &snapshot["graph"];
    let _ = writeln!(
        text,
        "\nGraph\n  Health: {}\n  Rate / quantum ({}): {} Hz / {}\n  Scheduling latency: {} ms\n  Peak DSP load: {}\n  XRUNs/errors: {}",
        if snapshot["healthy"] == true {
            "healthy"
        } else {
            "attention required"
        },
        safe(&graph["source"]),
        graph["rate"].as_u64().unwrap_or(0),
        graph["quantum"].as_u64().unwrap_or(0),
        graph["latencyMs"].as_f64().unwrap_or(0.0),
        graph["loadPercent"]
            .as_f64()
            .filter(|v| *v >= 0.0)
            .map(|v| format!("{v:.1}%"))
            .unwrap_or("idle/unavailable".into()),
        graph["errors"].as_u64().unwrap_or(0)
    );
    text.push_str("\nServices\n");
    for service in snapshot["services"].as_array().into_iter().flatten() {
        let _ = writeln!(
            text,
            "  {}: {}/{} (restarts {})",
            safe(&service["label"]),
            safe(&service["activeState"]),
            safe(&service["subState"]),
            service["restarts"].as_u64().unwrap_or(0)
        );
    }
    text.push_str("\nDevices\n");
    for device in snapshot["devices"].as_array().into_iter().flatten() {
        let output = device["direction"] == "output";
        let name = device["name"].as_str().unwrap_or("");
        let label = device["label"].as_str().unwrap_or("");
        let label = if label.is_empty() || (!name.is_empty() && label.contains(name)) {
            if output {
                "Unnamed output device"
            } else {
                "Unnamed input device"
            }
        } else {
            label
        };
        let _ = write!(
            text,
            "  {}{}: {} · {} · {}",
            if output { "Output" } else { "Input" },
            if device["default"] == true {
                " [default]"
            } else {
                ""
            },
            redact(label, user, host),
            safe(&device["format"]),
            safe(&device["channelMap"])
        );
        for field in ["profile", "codec"] {
            if device[field].as_str().is_some_and(|v| !v.is_empty()) {
                let _ = write!(text, " · {}", safe(&device[field]));
            }
        }
        text.push('\n');
    }
    text.push_str("\nActive routes\n");
    for route in snapshot["routes"].as_array().into_iter().flatten() {
        let labels = route["labels"]
            .as_array()
            .into_iter()
            .flatten()
            .map(&safe)
            .collect::<Vec<_>>();
        let _ = writeln!(
            text,
            "  {}: {}",
            safe(&route["direction"]),
            labels.join(" -> ")
        );
    }
    text.push_str("\nWarnings\n");
    for warning in snapshot["warnings"].as_array().into_iter().flatten() {
        let _ = writeln!(text, "  {}", safe(warning));
    }
    text.push_str("\nThis report omits logs, configuration files and internal device identifiers. Usernames, hostnames and hardware addresses are redacted.\n");
    text
}

fn redact(text: &str, user: &str, host: &str) -> String {
    // Redact before truncating: a boundary must not expose half of an address.
    let mut text = crate::storage::label(&serde_json::json!(text), 4096);
    for (needle, replacement) in [(user, "[redacted-user]"), (host, "[redacted-host]")] {
        if !needle.is_empty() && (needle.chars().count() >= 3 || text == needle) {
            text = text.replace(needle, replacement);
        }
    }
    let mut result = String::new();
    let mut offset = 0;
    while offset < text.len() {
        let bytes = &text.as_bytes()[offset..];
        let separated = bytes.len() >= 17
            && (0..17).all(|i| {
                if i % 3 == 2 {
                    b":_-".contains(&bytes[i])
                } else {
                    bytes[i].is_ascii_hexdigit()
                }
            });
        let compact = bytes.len() >= 12 && bytes[..12].iter().all(u8::is_ascii_hexdigit);
        if separated || compact {
            result.push_str("[redacted-address]");
            offset += if separated { 17 } else { 12 };
        } else {
            let ch = text[offset..].chars().next().unwrap();
            result.push(ch);
            offset += ch.len_utf8();
        }
    }
    result.chars().take(240).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn report_redacts_identifiers_and_ignores_unselected_fields() {
        let snapshot = json!({"devices":[{"name":"raw-node", "label":"raw-node", "direction":"output"}],
            "routes":[{"direction":"playback", "labels":["alice@workstation AA:BB:cc:DD:ee:ff aabbccddeeff", "Browser\u{202e}\nplaying"]}],
            "logs":"private logs", "media.title":"private title"});
        let report = support_report(&snapshot, "alice", "workstation");
        for forbidden in [
            "raw-node",
            "alice",
            "workstation",
            "AA:BB",
            "aabbcc",
            "private logs",
            "private title",
            "\u{202e}",
        ] {
            assert!(!report.contains(forbidden), "{forbidden}");
        }
        assert!(report.contains("[redacted-address]"));
        assert!(report.contains("Unnamed output device"));
        assert_eq!(redact("a DAC", "a", ""), "a DAC");
    }
}
