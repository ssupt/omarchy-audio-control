use std::fs;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener as StdListener, UnixStream as StdStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::{Semaphore, watch};
use tokio::task::JoinSet;
use tokio::time::{Instant, timeout, timeout_at};

use crate::protocol::{
    self, Failure, MAX_FRAME_BYTES, MAX_SNAPSHOT_BYTES, Request, Response, SNAPSHOT_CHUNK_BYTES,
};
use crate::service::Service;

pub const MAX_CLIENTS: usize = 16;
const FRAME_TIMEOUT: Duration = Duration::from_secs(5);
const WRITE_TIMEOUT: Duration = Duration::from_secs(3);

pub struct BoundSocket {
    listener: Option<StdListener>,
    path: PathBuf,
    identity: (u64, u64),
    _lock: fs::File,
}
impl BoundSocket {
    pub fn take_listener(&mut self) -> StdListener {
        self.listener
            .take()
            .expect("listener ownership transfers once")
    }
}
impl Drop for BoundSocket {
    fn drop(&mut self) {
        if let Ok(metadata) = fs::symlink_metadata(&self.path) {
            if metadata.file_type().is_socket() && (metadata.dev(), metadata.ino()) == self.identity
            {
                let _ = fs::remove_file(&self.path);
            }
        }
    }
}

pub fn bind_socket(path: &Path) -> io::Result<BoundSocket> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or_else(|| io::Error::other("Socket path requires a private parent directory"))?;
    if !parent.exists() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)?;
    }
    let metadata = fs::symlink_metadata(parent)?;
    // SAFETY: geteuid has no arguments or memory ownership requirements.
    let uid = unsafe { libc::geteuid() };
    if !metadata.is_dir() || metadata.uid() != uid || metadata.mode() & 0o077 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Socket parent must be private and owned by this user",
        ));
    }
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path.with_extension("lock"))?;
    let lock_meta = lock.metadata()?;
    if !lock_meta.is_file() || lock_meta.uid() != uid || lock_meta.nlink() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Unsafe socket lock",
        ));
    }
    // SAFETY: the descriptor is owned by lock and remains open for the call.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "Another audio service owns the socket",
        ));
    }
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if !metadata.file_type().is_socket() || metadata.uid() != uid {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "Refusing to replace a non-owned socket",
            ));
        }
        match StdStream::connect(path) {
            Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
                fs::remove_file(path)?
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    "Socket is already in use",
                ));
            }
        }
    }
    let listener = StdListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    let metadata = fs::symlink_metadata(path)?;
    Ok(BoundSocket {
        listener: Some(listener),
        path: path.into(),
        identity: (metadata.dev(), metadata.ino()),
        _lock: lock,
    })
}

/// Validate systemd's activation contract before taking ownership of FD 3.
/// CLOEXEC prevents future command adapters from retaining the listening socket.
pub fn systemd_listener() -> io::Result<Option<StdListener>> {
    let pid = std::env::var("LISTEN_PID")
        .ok()
        .and_then(|p| p.parse::<u32>().ok());
    if pid != Some(std::process::id()) {
        return Ok(None);
    }
    match std::env::var("LISTEN_FDS").ok().as_deref() {
        Some("0") => return Ok(None),
        Some("1") => (),
        _ => return Err(io::Error::other("Expected exactly one systemd listener")),
    }
    // SAFETY: fcntl/getsockopt validate FD 3 without adopting it; the local output
    // buffers have the sizes passed to libc. Ownership transfers exactly once.
    unsafe {
        let flags = libc::fcntl(3, libc::F_GETFD);
        if flags < 0 {
            return Err(io::Error::last_os_error());
        }
        for (option, expected) in [
            (libc::SO_TYPE, libc::SOCK_STREAM),
            (libc::SO_ACCEPTCONN, 1),
            (libc::SO_DOMAIN, libc::AF_UNIX),
        ] {
            let mut value: libc::c_int = 0;
            let mut length = std::mem::size_of_val(&value) as libc::socklen_t;
            if libc::getsockopt(
                3,
                libc::SOL_SOCKET,
                option,
                (&mut value as *mut libc::c_int).cast(),
                &mut length,
            ) != 0
            {
                return Err(io::Error::last_os_error());
            }
            if value != expected {
                return Err(io::Error::other(
                    "Inherited descriptor is not a listening Unix stream socket",
                ));
            }
        }
        if libc::fcntl(3, libc::F_SETFD, flags | libc::FD_CLOEXEC) != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Some(StdListener::from_raw_fd(3)))
    }
}

/// Healthy idle subscribers have no read deadline. Once a frame starts, its
/// deadline is fixed, so a trickle of bytes cannot keep it alive indefinitely.
pub async fn read_frame<R: AsyncBufRead + Unpin>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut frame = Vec::new();
    let mut deadline = None;
    loop {
        let chunk = if let Some(deadline) = deadline {
            timeout_at(deadline, reader.fill_buf())
                .await
                .map_err(|_| {
                    io::Error::new(io::ErrorKind::TimedOut, "Incomplete request frame")
                })??
        } else {
            reader.fill_buf().await?
        };
        if chunk.is_empty() {
            return if frame.is_empty() {
                Ok(None)
            } else {
                Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "Unterminated request",
                ))
            };
        }
        let end = chunk.iter().position(|byte| *byte == b'\n');
        let count = end.map_or(chunk.len(), |i| i + 1);
        if frame.len() + count > MAX_FRAME_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Request exceeds the frame limit",
            ));
        }
        frame.extend_from_slice(&chunk[..count]);
        reader.consume(count);
        if end.is_some() {
            frame.pop();
            if frame.last() == Some(&b'\r') {
                frame.pop();
            }
            return Ok(Some(frame));
        }
        deadline.get_or_insert_with(|| Instant::now() + FRAME_TIMEOUT);
    }
}

pub async fn write_frame<W: AsyncWrite + Unpin>(
    writer: &mut W,
    message: &impl Serialize,
) -> io::Result<()> {
    let mut encoded = protocol::encode(message).map_err(io::Error::other)?;
    if encoded.len() + 1 > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Response exceeds the frame limit",
        ));
    }
    encoded.push('\n');
    timeout(WRITE_TIMEOUT, async {
        writer.write_all(encoded.as_bytes()).await?;
        writer.flush().await
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "Client is not reading responses"))?
}

async fn write_snapshot<W: AsyncWrite + Unpin>(writer: &mut W, snapshot: &Value) -> io::Result<()> {
    let encoded = protocol::encode(snapshot).map_err(io::Error::other)?;
    if encoded.len() > MAX_SNAPSHOT_BYTES {
        return Err(io::Error::other("Snapshot exceeds the state limit"));
    }
    let parts = encoded.len().div_ceil(SNAPSHOT_CHUNK_BYTES);
    write_frame(
        writer,
        &protocol::event(
            "snapshot.begin",
            json!({"bytes": encoded.len(), "parts": parts}),
        ),
    )
    .await?;
    for (index, chunk) in encoded.as_bytes().chunks(SNAPSHOT_CHUNK_BYTES).enumerate() {
        // encode() guarantees ASCII, so chunk boundaries cannot split UTF-8.
        let text = std::str::from_utf8(chunk).expect("ASCII snapshot");
        write_frame(
            writer,
            &protocol::event("snapshot.part", json!({"index": index, "text": text})),
        )
        .await?;
    }
    write_frame(writer, &protocol::event("snapshot.end", json!({}))).await
}

async fn write_latest_snapshot<W: AsyncWrite + Unpin>(
    writer: &mut W,
    state: &mut watch::Receiver<Arc<Value>>,
    last_revision: &mut Option<String>,
) -> io::Result<()> {
    let snapshot = {
        let current = state.borrow_and_update();
        if current["revision"].as_str() == last_revision.as_deref() {
            return Ok(());
        }
        current.clone()
    };
    write_snapshot(writer, &snapshot).await?;
    *last_revision = snapshot["revision"].as_str().map(str::to_owned);
    Ok(())
}

pub async fn serve<R, W>(
    mut reader: R,
    mut writer: W,
    service: Arc<Service>,
    mut shutdown: watch::Receiver<bool>,
) -> io::Result<()>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut state = service.subscribe();
    let mut negotiated = false;
    let mut subscribed = false;
    let mut last_revision = None;
    let mut lease = None;
    let mut operations = JoinSet::<(String, crate::protocol::Result<Value>)>::new();
    let handshake_deadline = Instant::now() + FRAME_TIMEOUT;
    loop {
        let read = read_frame(&mut reader);
        tokio::pin!(read);
        let incoming = loop {
            tokio::select! {
                biased;
                _ = shutdown.changed() => return Ok(()),
                incoming = &mut read => break incoming,
                Some(completed) = operations.join_next(), if !operations.is_empty() => {
                    let (id,result) = completed.map_err(io::Error::other)?;
                    if subscribed {
                        write_latest_snapshot(&mut writer, &mut state, &mut last_revision).await?;
                    }
                    write_frame(&mut writer,&Response::new(Some(&id),result)).await?;
                },
                _ = tokio::time::sleep_until(handshake_deadline), if !negotiated => return Err(io::Error::new(io::ErrorKind::TimedOut, "Handshake timed out")),
                changed = state.changed(), if subscribed => {
                    if changed.is_err() { return Ok(()); }
                    write_latest_snapshot(&mut writer, &mut state, &mut last_revision).await?;
                }
            }
        };
        let frame = match incoming {
            Ok(Some(frame)) => frame,
            Ok(None) => return Ok(()),
            Err(error) => {
                let failure = Failure::new("invalid_frame", error.to_string());
                let _ = write_frame(&mut writer, &Response::new(None, Err(failure))).await;
                return Err(error);
            }
        };
        let request = match Request::decode(&frame) {
            Ok(request) => request,
            Err(error) => {
                write_frame(&mut writer, &Response::new(None, Err(error))).await?;
                return Ok(());
            }
        };
        if !negotiated && request.method != "hello" {
            write_frame(
                &mut writer,
                &Response::new(
                    Some(&request.id),
                    Err(Failure::new(
                        "not_ready",
                        "Negotiate before issuing commands",
                    )),
                ),
            )
            .await?;
            continue;
        }
        let id = request.id.clone();
        let method = request.method.clone();
        let immediate = matches!(method.as_str(), "hello" | "health" | "state.subscribe");
        if !immediate {
            if operations.len() >= 32 {
                write_frame(
                    &mut writer,
                    &Response::new(
                        Some(&id),
                        Err(Failure::new("busy", "Connection request queue is full")),
                    ),
                )
                .await?;
                continue;
            }
            match service.clone().dispatch(request) {
                Err(error) => {
                    write_frame(&mut writer, &Response::new(Some(&id), Err(error))).await?
                }
                Ok(operation) => {
                    operations.spawn(async move {
                        (
                            id,
                            operation.await.unwrap_or_else(|_| {
                                Err(Failure::unknown("Audio operation stopped unexpectedly"))
                            }),
                        )
                    });
                }
            }
            continue;
        }
        let result = service.handle(&request).await;
        let success = result.is_ok();
        // Publish completion state before invoking the UI callback. A callback
        // may legitimately submit the next operation using that busy/store state.
        if subscribed {
            write_latest_snapshot(&mut writer, &mut state, &mut last_revision).await?;
        }
        write_frame(&mut writer, &Response::new(Some(&id), result)).await?;
        if success && method == "hello" {
            negotiated = true;
        }
        if success && method == "state.subscribe" {
            subscribed = true;
            if lease.is_none() {
                lease = Some(service.lease());
            }
            write_latest_snapshot(&mut writer, &mut state, &mut last_revision).await?;
        }
    }
}

pub async fn serve_listener(
    listener: StdListener,
    service: Arc<Service>,
    mut shutdown: watch::Receiver<bool>,
) -> io::Result<()> {
    listener.set_nonblocking(true)?;
    let listener = UnixListener::from_std(listener)?;
    let permits = Arc::new(Semaphore::new(MAX_CLIENTS));
    let mut clients = JoinSet::new();
    loop {
        tokio::select! {
            _ = shutdown.changed() => break,
            _ = tokio::time::sleep(Duration::from_secs(30)), if clients.is_empty() => break,
            Some(result) = clients.join_next(), if !clients.is_empty() => {
                if let Err(error) = result { eprintln!("client task failed: {error}"); }
            }
            accepted = listener.accept() => {
                let (stream, _) = match accepted {
                    Ok(connection) => connection,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => {
                        eprintln!("could not accept client: {error}");
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        continue;
                    }
                };
                let Ok(permit) = permits.clone().try_acquire_owned() else { drop(stream); continue; };
                let service = service.clone();
                let shutdown = shutdown.clone();
                clients.spawn(async move {
                    let _permit = permit;
                    let (reader, writer) = stream.into_split();
                    if let Err(error) = serve(BufReader::new(reader), writer, service, shutdown).await {
                        eprintln!("client disconnected: {error}");
                    }
                });
            }
        }
    }
    // Connections see the shutdown watch. Do not let stalled clients prevent exit.
    let _ = timeout(Duration::from_secs(5), async {
        while clients.join_next().await.is_some() {}
    })
    .await;
    clients.abort_all();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    #[tokio::test]
    async fn partial_frames_and_multiple_requests_are_framed_correctly() {
        let (mut tx, rx) = tokio::io::duplex(128);
        let producer = tokio::spawn(async move {
            tx.write_all(b"one\r").await.unwrap();
            tokio::task::yield_now().await;
            tx.write_all(b"\ntwo\n").await.unwrap();
        });
        let mut reader = BufReader::new(rx);
        assert_eq!(read_frame(&mut reader).await.unwrap().unwrap(), b"one");
        assert_eq!(read_frame(&mut reader).await.unwrap().unwrap(), b"two");
        assert!(read_frame(&mut reader).await.unwrap().is_none());
        producer.await.unwrap();
    }
    #[tokio::test]
    async fn rejects_unterminated_and_oversized_frames() {
        let mut truncated = BufReader::new(&b"unterminated"[..]);
        assert_eq!(
            read_frame(&mut truncated).await.unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
        let data = vec![b'x'; MAX_FRAME_BYTES + 1];
        let mut oversized = BufReader::new(data.as_slice());
        assert_eq!(
            read_frame(&mut oversized).await.unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }
    #[tokio::test]
    async fn serves_negotiated_requests_and_bounded_snapshot_parts() {
        let input = concat!(
            "{\"version\":1,\"id\":\"1\",\"method\":\"hello\"}\n",
            "{\"version\":1,\"id\":\"2\",\"method\":\"state.subscribe\"}\n",
            "{\"version\":1,\"id\":\"3\",\"method\":\"health\"}\n",
            "{\"version\":1,\"id\":\"4\",\"method\":\"health\"}\n"
        );
        let (writer, mut output) = tokio::io::duplex(16384);
        let (shutdown_tx, shutdown) = watch::channel(false);
        let task = tokio::spawn(serve(
            BufReader::new(input.as_bytes()),
            writer,
            Service::new().unwrap(),
            shutdown,
        ));
        let mut data = String::new();
        output.read_to_string(&mut data).await.unwrap();
        task.await.unwrap().unwrap();
        drop(shutdown_tx);
        let replies: Vec<Value> = data
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(
            replies.len(),
            7,
            "unchanged state must not accompany health replies"
        );
        assert_eq!(replies[0]["result"]["transport"], "jsonl-ascii");
        assert_eq!(replies[2]["event"], "snapshot.begin");
        let snapshot: Value =
            serde_json::from_str(replies[3]["data"]["text"].as_str().unwrap()).unwrap();
        assert!(snapshot["epoch"].is_string());
        assert_eq!(replies[4]["event"], "snapshot.end");
        assert_eq!(replies[5]["id"], "3");
        assert_eq!(replies[6]["id"], "4");
    }
}
