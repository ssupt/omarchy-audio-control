//! Temporary compatibility boundary for domains whose hardware/rollback parity
//! is still covered by the existing helper suite. No client supplies a program
//! or shell fragment; only this fixed allowlist can launch a packaged helper.
use crate::files::FileLock;
use crate::protocol::{Failure, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Call {
    pub helper: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub generation: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Output {
    pub exit_code: i32,
    pub stdout: String,
    pub outcome: &'static str,
}
impl Call {
    pub fn new(helper: &str, args: Vec<String>) -> Self {
        Self {
            helper: helper.into(),
            args,
            generation: String::new(),
        }
    }
    pub fn validate(&self) -> Result<()> {
        let (min, max) = match self.helper.as_str() {
            "audio-stream-routes" | "audio-resolve-output-sink" | "audio-sink-availability" => {
                (0, 0)
            }
            "audio-output-set-default" | "audio-input-set-default" => (2, 4),
            "audio-stream-route-set" => (3, 4),
            "audio-output-groups" => (1, 4),
            "audio-diagnostics" if self.args == ["snapshot"] => (1, 1),
            _ => return Err(Failure::new("method_not_found", "Unknown audio adapter")),
        };
        if !(min..=max).contains(&self.args.len())
            || self
                .args
                .iter()
                .any(|arg| arg.len() > 8192 || arg.contains('\0'))
        {
            return Err(Failure::new("invalid_params", "Invalid adapter arguments"));
        }
        // Helpers retain their strict domain-specific argument validation.
        Ok(())
    }
    pub fn mutating(&self) -> bool {
        !matches!(
            self.helper.as_str(),
            "audio-stream-routes"
                | "audio-resolve-output-sink"
                | "audio-sink-availability"
                | "audio-diagnostics"
        )
    }
}

#[derive(Clone)]
pub struct Adapter {
    directory: PathBuf,
    _embedded: Option<std::sync::Arc<tempfile::TempDir>>,
}
impl Adapter {
    pub fn from_environment() -> Result<Self> {
        let mut embedded = None;
        let directory = if let Some(path) = std::env::var_os("OMARCHY_AUDIO_HELPERS_DIR") {
            PathBuf::from(path)
        } else {
            // A plugin update may remove/replace its checkout while an older
            // transaction is still draining. Its helpers must remain identical
            // to the ones with which this binary was built.
            mod bundled {
                include!(concat!(env!("OUT_DIR"), "/helpers.rs"));
            }
            let directory = tempfile::Builder::new()
                .prefix("omarchy-audio-adapters-")
                .tempdir()?;
            for (name, bytes) in bundled::HELPERS {
                use std::os::unix::fs::PermissionsExt;
                let path = directory.path().join(name);
                std::fs::write(&path, bytes)?;
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
            }
            let path = directory.path().to_owned();
            embedded = Some(std::sync::Arc::new(directory));
            path
        };
        if !directory.is_absolute() {
            return Err(Failure::new(
                "unsafe_path",
                "Helper directory must be absolute",
            ));
        }
        Ok(Self {
            directory,
            _embedded: embedded,
        })
    }
    pub async fn run(&self, call: &Call, lock: Option<&FileLock>) -> Result<Output> {
        call.validate()?;
        if call.mutating() && lock.is_none() {
            return Err(Failure::new(
                "internal_error",
                "Mutation has no transaction owner",
            ));
        }
        let mut command = Command::new("/bin/bash");
        command
            .arg(self.directory.join(&call.helper))
            .args(&call.args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .process_group(0);
        if let Some(lock) = lock {
            let descriptor = lock.descriptor();
            command.env("AUDIO_CONTROL_COORDINATOR_LOCK", "197");
            // SAFETY: dup2 is async-signal-safe. The parent keeps the descriptor
            // owned until this child and its process group have finished.
            unsafe {
                command.pre_exec(move || {
                    if libc::dup2(descriptor, 197) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    if libc::fcntl(197, libc::F_SETFD, 0) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }
        let mut child = command.spawn()?;
        let pid = child
            .id()
            .ok_or_else(|| Failure::new("internal_error", "Missing child identity"))?
            as i32;
        let output_limit = if call.helper == "audio-diagnostics" {
            crate::protocol::MAX_SNAPSHOT_BYTES
        } else {
            32768
        };
        let mut stdout = child.stdout.take().unwrap().take(output_limit as u64 + 1);
        let mut stderr = child.stderr.take().unwrap().take(32769);
        let work = async {
            let mut out = Vec::new();
            let mut err = Vec::new();
            tokio::try_join!(stdout.read_to_end(&mut out), stderr.read_to_end(&mut err))?;
            if out.len() > output_limit || err.len() > 32768 {
                return Err(std::io::Error::other("Adapter output exceeded its limit"));
            }
            let status = child.wait().await?;
            Ok::<_, std::io::Error>((status, out, err))
        };
        let result = tokio::time::timeout(Duration::from_secs(30), work).await;
        match result {
            Ok(Ok((status, out, _err))) => {
                let exit_code = status.code().unwrap_or(4);
                let stdout = String::from_utf8(out)
                    .map_err(|_| Failure::unknown("Audio adapter returned invalid text"))?;
                Ok(Output {
                    exit_code,
                    stdout,
                    outcome: match exit_code {
                        0 => "applied",
                        2 => "persistence_failed",
                        3 => "skipped",
                        4 => "unknown",
                        _ => "rejected",
                    },
                })
            }
            _ => {
                // A timeout is an unknown outcome. Kill the entire supervised
                // group and reap before releasing ownership; never replay it.
                // SAFETY: pid identifies our unreaped child/group, not an arbitrary process.
                unsafe {
                    libc::kill(-pid, libc::SIGKILL);
                }
                let _ = child.wait().await;
                Err(Failure::unknown(
                    "Audio adapter timed out or exceeded its output limit",
                ))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_fixed_programs_are_accepted() {
        for helper in [
            "../audio-input-set-default",
            "/bin/sh",
            "audio-input-set-default;id",
            "audio-rust-backend",
        ] {
            assert!(Call::new(helper, vec![]).validate().is_err());
        }
        assert!(Call::new("audio-stream-routes", vec![]).validate().is_ok());
        assert!(
            Call::new("audio-stream-routes", vec!["extra".into()])
                .validate()
                .is_err()
        );
    }
}
