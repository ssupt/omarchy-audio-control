//! Versioned control messages. Native handles never cross this boundary.
use crate::PROTOCOL_VERSION;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const MAX_FRAME_BYTES: usize = 256 * 1024;
pub const MAX_SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
pub const SNAPSHOT_CHUNK_BYTES: usize = 32 * 1024;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u32,
    pub id: String,
    pub method: String,
    #[serde(default = "empty_params")]
    pub params: Value,
}
fn empty_params() -> Value {
    serde_json::json!({})
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Failure {
    pub code: String,
    pub message: String,
    /// "unknown" means a mutation might have landed; clients must resynchronize.
    pub outcome: String,
}
impl Failure {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            outcome: "rejected".into(),
        }
    }
    pub fn unknown(message: impl Into<String>) -> Self {
        Self {
            code: "outcome_unknown".into(),
            message: message.into(),
            outcome: "unknown".into(),
        }
    }
}
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}
impl std::error::Error for Failure {}
impl From<std::io::Error> for Failure {
    fn from(error: std::io::Error) -> Self {
        Self::new("io_error", error.to_string())
    }
}
pub type Result<T> = std::result::Result<T, Failure>;

impl Request {
    pub fn decode(frame: &[u8]) -> Result<Self> {
        let request: Self = serde_json::from_slice(frame)
            .map_err(|_| Failure::new("invalid_request", "Expected a control request object"))?;
        if request.version != PROTOCOL_VERSION {
            return Err(Failure::new(
                "unsupported_version",
                "Unsupported protocol version",
            ));
        }
        if request.id.is_empty()
            || request.id.len() > 128
            || !request
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_:.".contains(&b))
        {
            return Err(Failure::new(
                "invalid_request",
                "Request id must be a short ASCII identifier",
            ));
        }
        if request.method.is_empty()
            || request.method.len() > 128
            || !request
                .method
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b"._".contains(&b))
            || !request.params.is_object()
        {
            return Err(Failure::new(
                "invalid_request",
                "Invalid method or parameters",
            ));
        }
        Ok(request)
    }
    pub fn params<T: serde::de::DeserializeOwned>(&self) -> Result<T> {
        serde_json::from_value(self.params.clone())
            .map_err(|_| Failure::new("invalid_params", "Invalid command parameters"))
    }
}

#[derive(Serialize)]
pub struct Response<'a> {
    version: u32,
    id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<Failure>,
}
impl<'a> Response<'a> {
    pub fn new(id: Option<&'a str>, result: Result<Value>) -> Self {
        match result {
            Ok(value) => Self {
                version: PROTOCOL_VERSION,
                id,
                result: Some(value),
                error: None,
            },
            Err(error) => Self {
                version: PROTOCOL_VERSION,
                id,
                result: None,
                error: Some(error),
            },
        }
    }
}

/// ASCII output lets QML bound raw chunks without corrupting UTF-8 split across
/// socket reads. JSON.parse restores escaped Unicode, including surrogate pairs.
/// The frame byte limit includes the final newline.
pub fn encode(value: &impl Serialize) -> Result<String> {
    let json = serde_json::to_string(value)
        .map_err(|_| Failure::new("encoding_error", "Could not encode a response"))?;
    // Most snapshots are already ASCII; keep the serialization buffer instead
    // of allocating and copying a second complete state document.
    if json.is_ascii() {
        return Ok(json);
    }
    let mut ascii = String::with_capacity(json.len());
    for ch in json.chars() {
        if ch.is_ascii() {
            ascii.push(ch);
        } else {
            use std::fmt::Write;
            let mut buffer = [0; 2];
            for unit in ch.encode_utf16(&mut buffer) {
                write!(ascii, "\\u{unit:04x}").expect("writing into a String");
            }
        }
    }
    Ok(ascii)
}
pub fn event(name: &str, data: Value) -> Value {
    serde_json::json!({"version": PROTOCOL_VERSION, "event": name, "data": data})
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn accepts_only_bounded_typed_requests() {
        assert!(Request::decode(br#"{"version":1,"id":"qml-1","method":"health"}"#).is_ok());
        for frame in [
            r#"{"version":2,"id":"qml-1","method":"health"}"#,
            r#"{"version":1,"id":{},"method":"health"}"#,
            r#"{"version":1,"id":"","method":"health"}"#,
            r#"{"version":1,"id":"qml-1","method":"health","params":[]}"#,
            r#"{"version":1,"id":"qml-1","method":"health","extra":true}"#,
        ] {
            assert!(Request::decode(frame.as_bytes()).is_err(), "{frame}");
        }
    }
    #[test]
    fn unicode_is_ascii_on_wire_and_lossless_after_decoding() {
        let value = serde_json::json!({"label": "Cuffie 🎧 · 日本語", "text": "\"\\\n"});
        let encoded = encode(&value).unwrap();
        assert!(encoded.is_ascii());
        assert_eq!(serde_json::from_str::<Value>(&encoded).unwrap(), value);
    }
    #[test]
    fn failures_distinguish_rejection_from_unknown_outcomes() {
        let reply = Response::new(Some("id"), Err(Failure::unknown("Connection lost")));
        let value = serde_json::to_value(reply).unwrap();
        assert_eq!(value["error"]["outcome"], "unknown");
        assert!(value.get("result").is_none());
    }
}
