//! The shell owns a small stdio relay. The daemon outlives a UI reload long
//! enough to verify admitted commands, then exits when its clients disappear.
use serde_json::json;
use std::{
    io,
    os::fd::FromRawFd,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
    process::Command,
    time::{Instant, sleep, timeout},
};

pub const BUILD_ID: &str = env!("AUDIO_BUILD_ID");
pub const BUILD_TARGET: &str = env!("AUDIO_BUILD_TARGET");

// Tokio's standard stdin uses an uncancellable blocking read. A daemon crash
// must close the relay immediately even while the shell keeps stdin open.
struct Pipe(tokio::io::unix::AsyncFd<std::fs::File>);
impl Pipe {
    fn new(fd: i32) -> io::Result<Self> {
        // SAFETY: duplicate a standard descriptor and transfer that owned copy
        // into File. Only this relay reads/writes its standard pipes.
        let file = unsafe {
            let copy = libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3);
            if copy < 0 {
                return Err(io::Error::last_os_error());
            }
            std::fs::File::from_raw_fd(copy)
        };
        use std::os::fd::AsRawFd;
        // SAFETY: file owns a valid descriptor for both fcntl calls.
        unsafe {
            let flags = libc::fcntl(file.as_raw_fd(), libc::F_GETFL);
            if flags < 0
                || libc::fcntl(file.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) < 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(Self(tokio::io::unix::AsyncFd::new(file)?))
    }
    async fn read(&self, buffer: &mut [u8]) -> io::Result<usize> {
        use std::io::Read;
        loop {
            let mut ready = self.0.readable().await?;
            if let Ok(result) = ready.try_io(|fd| fd.get_ref().read(buffer)) {
                return result;
            }
        }
    }
    async fn write_all(&self, mut bytes: &[u8]) -> io::Result<()> {
        use std::io::Write;
        while !bytes.is_empty() {
            let mut ready = self.0.writable().await?;
            if let Ok(result) = ready.try_io(|fd| fd.get_ref().write(bytes)) {
                let size = result?;
                if size == 0 {
                    return Err(io::ErrorKind::WriteZero.into());
                }
                bytes = &bytes[size..];
            }
        }
        Ok(())
    }
}

pub fn socket_path() -> io::Result<PathBuf> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .ok_or_else(|| io::Error::other("XDG_RUNTIME_DIR is not set"))?;
    let runtime = PathBuf::from(runtime);
    if !runtime.is_absolute() {
        return Err(io::Error::other("XDG_RUNTIME_DIR must be absolute"));
    }
    Ok(runtime
        .join("omarchy-audio-control")
        .join(format!("backend-{}.sock", &BUILD_ID[..24])))
}

async fn connect_ready(path: &Path) -> io::Result<UnixStream> {
    let mut socket = UnixStream::connect(path).await?;
    // A dying daemon may still accept connections. Probe before forwarding any
    // client bytes, so retrying startup cannot replay an admitted operation.
    timeout(Duration::from_secs(1), async {
        crate::server::write_frame(
            &mut socket,
            &json!({
                "version": 1, "id": "relay-startup", "method": "hello", "params": {}
            }),
        )
        .await?;
        let frame = crate::server::read_frame(&mut BufReader::new(&mut socket))
            .await?
            .ok_or_else(|| io::Error::from(io::ErrorKind::UnexpectedEof))?;
        let reply: serde_json::Value = serde_json::from_slice(&frame)?;
        if reply["version"] != 1
            || reply["id"] != "relay-startup"
            || reply["result"]["buildId"] != BUILD_ID
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Audio backend startup identity mismatch",
            ));
        }
        Ok(())
    })
    .await
    .map_err(|_| io::Error::from(io::ErrorKind::TimedOut))??;
    Ok(socket)
}

pub async fn relay() -> io::Result<()> {
    let stdin = Pipe::new(0)?;
    let stdout = Pipe::new(1)?;
    let path = socket_path()?;
    let socket = match connect_ready(&path).await {
        Ok(socket) => socket,
        Err(_) => {
            // No shell, downloaded code, installation hooks or user units.
            // The executable contains the matching compatibility adapters.
            let mut command = Command::new(std::env::current_exe()?);
            command
                .arg("--plugin-daemon")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            // SAFETY: setsid is async-signal-safe. A shell reload may terminate
            // the relay's process group; accepted work belongs to the daemon.
            unsafe {
                command.pre_exec(|| {
                    if libc::setsid() < 0 {
                        return Err(io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
            let mut child = command.spawn()?;
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                // Concurrent launches converge on the same locked socket. Even
                // if our child loses that race, connect to the winning daemon.
                if let Ok(socket) = connect_ready(&path).await {
                    break socket;
                }
                let _ = child.try_wait()?;
                if Instant::now() >= deadline {
                    return Err(io::Error::other(
                        "Audio backend could not start; check runtime permissions and PipeWire dependencies",
                    ));
                }
                sleep(Duration::from_millis(25)).await;
            }
        }
    };
    let (mut reader, mut writer) = socket.into_split();
    let upstream = async {
        let mut buffer = [0; 8192];
        loop {
            let size = stdin.read(&mut buffer).await?;
            if size == 0 {
                return Ok::<_, io::Error>(());
            }
            writer.write_all(&buffer[..size]).await?;
        }
    };
    let downstream = async {
        let mut buffer = [0; 8192];
        loop {
            let size = reader.read(&mut buffer).await?;
            if size == 0 {
                return Ok::<_, io::Error>(());
            }
            stdout.write_all(&buffer[..size]).await?;
        }
    };
    tokio::select! { result = upstream => result, result = downstream => result }
}
