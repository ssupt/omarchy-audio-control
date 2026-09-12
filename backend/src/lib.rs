pub mod adapter;
pub mod automation;
pub mod file_watch;
pub mod files;
pub mod launch;
pub mod microphone;
pub mod native;
pub mod profiles;
pub mod protocol;
pub mod scenes;
pub mod server;
pub mod service;
pub mod storage;

pub const PROTOCOL_VERSION: u32 = 1;
pub const SERVICE_NAME: &str = "omarchy-audio-service";
