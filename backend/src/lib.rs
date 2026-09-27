pub mod automation;
pub mod diagnostics;
pub mod file_watch;
pub mod files;
pub mod groups;
pub mod launch;
pub mod microphone;
pub mod native;
pub mod outputs;
pub mod profiles;
pub mod protocol;
pub mod pulse;
pub mod scenes;
pub mod server;
pub mod service;
pub mod storage;

pub const PROTOCOL_VERSION: u32 = 1;
pub const SERVICE_NAME: &str = "omarchy-audio-service";

pub mod defaults;
pub mod routing;
