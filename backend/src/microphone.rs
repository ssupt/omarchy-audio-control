//! Finite microphone probes. The clip stays in memory and disappears when the
//! owner closes, the service exits, or the graph/source identity changes.
use crate::native::{self, Handle, Identity};
use crate::protocol::{Failure, Result};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;
use tokio::sync::watch;

const CLIP_BYTES: usize = 48000 * 5 * 2; // Five seconds of mono s16 audio.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Control {
    Continue,
    Stop,
    Discard,
}

pub async fn run(
    record: bool,
    native: &Handle,
    identity: Option<Identity>,
    clip: Vec<u8>,
    mut cancel: watch::Receiver<Control>,
) -> Result<Vec<u8>> {
    if *cancel.borrow() != Control::Continue {
        return Ok(if *cancel.borrow() == Control::Discard {
            Vec::new()
        } else {
            clip
        });
    }
    let mut command = Command::new(if record { "pw-record" } else { "pw-play" });
    command.args(["--raw", "--rate=48000", "--channels=1", "--format=s16",
        "--properties=application.id=ssupt.audio-control node.name=omarchy_audio_test media.name=Microphone-test"])
        .stderr(Stdio::null()).kill_on_drop(true).process_group(0);
    let parent = std::process::id() as i32;
    // SAFETY: these Linux calls allocate no memory. A daemon crash must stop
    // recording/playback too, including the race before the child sets prctl.
    unsafe {
        command.pre_exec(move || {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::getppid() != parent {
                return Err(std::io::Error::other("Microphone supervisor exited"));
            }
            Ok(())
        });
    }
    if record {
        let identity = identity
            .as_ref()
            .ok_or_else(|| Failure::new("invalid_params", "Microphone identity is required"))?;
        let graph = native.snapshot();
        let source = native::validate_identity(&graph, identity)?;
        if source
            .properties
            .get("media.class")
            .is_none_or(|v| v != "Audio/Source")
            || source.name.ends_with(".monitor")
            || source
                .properties
                .get("device.class")
                .is_some_and(|v| v.eq_ignore_ascii_case("monitor"))
            || source.audio.muted != Some(false)
        {
            return Err(Failure::new(
                "invalid_target",
                "Select an unmuted microphone",
            ));
        }
        command
            .arg(format!("--target={}", source.serial))
            .arg("--sample-count=240000");
        command.stdin(Stdio::null()).stdout(Stdio::piped());
    } else {
        if clip.len() < 2 || clip.len() > CLIP_BYTES || clip.len() % 2 != 0 {
            return Err(Failure::new(
                "no_clip",
                "Record a microphone test before playing it",
            ));
        }
        command.stdin(Stdio::piped()).stdout(Stdio::null());
    }
    command.arg("-");
    let mut child = command.spawn()?;
    let pid = child.id().unwrap() as i32;
    let mut stdout = child.stdout.take();
    let mut stdin = child.stdin.take();
    let mut data = Vec::new();
    let transfer = async {
        if let Some(stdout) = stdout.as_mut() {
            stdout
                .take(CLIP_BYTES as u64)
                .read_to_end(&mut data)
                .await?;
        }
        if let Some(stdin) = stdin.as_mut() {
            stdin.write_all(&clip).await?;
            stdin.shutdown().await?;
        }
        Ok::<_, std::io::Error>(())
    };
    let mut graph = native.subscribe();
    let disconnected = async {
        while graph.changed().await.is_ok() {
            let live = graph.borrow_and_update().clone();
            if !live.ready {
                return;
            }
            if let Some(identity) = &identity {
                if native::validate_identity(&live, identity).is_err()
                    || live
                        .nodes
                        .get(&identity.id)
                        .is_some_and(|n| n.audio.muted != Some(false))
                {
                    return;
                }
            }
        }
    };
    tokio::pin!(disconnected);
    // Do not reap until the stream has finished, or cancellation has killed the
    // group. This keeps the PID reserved throughout group signalling.
    let completed = tokio::select! {
        result = transfer => result.is_ok(),
        _ = cancel.changed() => false,
        _ = &mut disconnected => { return finish_cancel(&mut child,pid).await.and(Err(Failure::new("source_changed", "Microphone or audio graph changed"))); },
        _ = tokio::time::sleep(Duration::from_secs(8)) => { return finish_cancel(&mut child,pid).await.and(Err(Failure::new("timeout", "Microphone test timed out"))); }
    };
    let stopped = *cancel.borrow();
    // ChildStdin::shutdown flushes but does not necessarily close the pipe.
    // Drop our writer so a player reading to EOF can finish.
    drop(stdin);
    // Own the sample limit: pw-record can exit unsuccessfully after reaching
    // --sample-count even though it produced the complete recording.
    if !completed || (record && data.len() == CLIP_BYTES) {
        finish_cancel(&mut child, pid).await?;
    } else {
        tokio::select! {
            status = child.wait() => { if !status?.success() { return Err(Failure::new("test_failed", "Microphone test could not finish")); } },
            _ = cancel.changed() => { finish_cancel(&mut child,pid).await?; },
            _ = &mut disconnected => { finish_cancel(&mut child,pid).await?; return Err(Failure::new("source_changed", "Audio graph changed during playback")); },
            _ = tokio::time::sleep(Duration::from_secs(8)) => { finish_cancel(&mut child,pid).await?; return Err(Failure::new("timeout", "Microphone playback timed out")); }
        }
    }
    if stopped == Control::Discard || *cancel.borrow() == Control::Discard {
        return Ok(Vec::new());
    }
    if record {
        data.truncate(data.len() / 2 * 2);
        if data.len() < 2 {
            return Err(Failure::new(
                "empty_clip",
                "No microphone samples were recorded",
            ));
        }
        Ok(data)
    } else {
        Ok(clip)
    }
}
async fn finish_cancel(child: &mut tokio::process::Child, pid: i32) -> Result<()> {
    // SAFETY: this is our owned, unreaped child/process group.
    unsafe {
        libc::kill(-pid, libc::SIGKILL);
    }
    child.wait().await?;
    Ok(())
}
