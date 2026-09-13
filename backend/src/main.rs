use std::env;
use std::error::Error;
use std::io;
use std::path::PathBuf;
use std::time::Duration;

use omarchy_audio_service::protocol::{self, MAX_FRAME_BYTES};
use omarchy_audio_service::server::{
    bind_socket, read_frame, serve, serve_listener, systemd_listener, write_frame,
};
use omarchy_audio_service::service::Service;
use serde_json::{Value, json};
use tokio::io::BufReader;
use tokio::sync::watch;

#[derive(Default)]
struct Options {
    socket: Option<PathBuf>,
    stdio: bool,
    request: Option<(String, Value)>,
    plugin: bool,
    plugin_daemon: bool,
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("omarchy-audio-service: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn Error>> {
    let options = parse_args(env::args().skip(1))?;
    if options.plugin {
        return Ok(omarchy_audio_service::launch::relay().await?);
    }
    if let Some((method, params)) = options.request {
        let path = options.socket.map(Ok).unwrap_or_else(default_socket_path)?;
        return request(&path, &method, params).await;
    }
    let service = Service::start()?;
    let (shutdown, receiver) = watch::channel(false);
    tokio::spawn(async move {
        let mut term =
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(signal) => signal,
                Err(_) => return,
            };
        tokio::select! { _ = tokio::signal::ctrl_c() => (), _ = term.recv() => () }
        shutdown.send_replace(true);
    });
    if options.stdio {
        let result = serve(
            BufReader::new(tokio::io::stdin()),
            tokio::io::stdout(),
            service.clone(),
            receiver,
        )
        .await;
        service.drain().await;
        return Ok(result?);
    }
    if options.socket.is_none() && !options.plugin_daemon {
        if let Some(listener) = systemd_listener()? {
            let result = serve_listener(listener, service.clone(), receiver).await;
            service.drain().await;
            return Ok(result?);
        }
    }
    let path = if options.plugin_daemon {
        omarchy_audio_service::launch::socket_path()?
    } else {
        options.socket.map(Ok).unwrap_or_else(default_socket_path)?
    };
    let mut socket = bind_socket(&path)?;
    eprintln!("listening on {}", path.display());
    let result = serve_listener(socket.take_listener(), service.clone(), receiver).await;
    service.drain().await;
    Ok(result?)
}

async fn request(
    path: &std::path::Path,
    method: &str,
    params: Value,
) -> Result<(), Box<dyn Error>> {
    let stream = tokio::net::UnixStream::connect(path).await?;
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    for (id, method, params) in [("cli-hello", "hello", json!({})), ("cli-1", method, params)] {
        write_frame(
            &mut writer,
            &json!({"version": 1, "id": id, "method": method, "params": params}),
        )
        .await?;
        let frame = tokio::time::timeout(Duration::from_secs(120), read_frame(&mut reader))
            .await??
            .ok_or("Audio service closed the connection; command outcome may be unknown")?;
        let reply: Value = serde_json::from_slice(&frame)?;
        if reply["version"] != 1 || reply["id"] != id || reply.get("event").is_some() {
            return Err("Invalid service response".into());
        }
        if let Some(error) = reply.get("error") {
            let failure: protocol::Failure = serde_json::from_value(error.clone())?;
            return Err(failure.into());
        }
        if id == "cli-1" {
            println!("{}", serde_json::to_string(&reply["result"])?);
        }
    }
    Ok(())
}

fn default_socket_path() -> io::Result<PathBuf> {
    let runtime = env::var_os("XDG_RUNTIME_DIR")
        .ok_or_else(|| io::Error::other("XDG_RUNTIME_DIR is not set"))?;
    let runtime = PathBuf::from(runtime);
    if !runtime.is_absolute() {
        return Err(io::Error::other("XDG_RUNTIME_DIR must be absolute"));
    }
    Ok(runtime.join("omarchy-audio-control/backend.sock"))
}

fn parse_args(mut args: impl Iterator<Item = String>) -> Result<Options, Box<dyn Error>> {
    let mut options = Options::default();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--plugin" if !options.plugin => options.plugin = true,
            "--plugin-daemon" if !options.plugin_daemon => options.plugin_daemon = true,
            "--build-info" => {
                println!(
                    "{}",
                    json!({"buildId":omarchy_audio_service::launch::BUILD_ID,
                    "target":omarchy_audio_service::launch::BUILD_TARGET,
                    "version":env!("CARGO_PKG_VERSION"),"protocolVersion":1})
                );
                std::process::exit(0);
            }
            "--socket" if options.socket.is_none() => {
                let path = PathBuf::from(args.next().ok_or("--socket requires a path")?);
                if !path.is_absolute() {
                    return Err("--socket requires an absolute path".into());
                }
                options.socket = Some(path);
            }
            "--stdio" if !options.stdio => options.stdio = true,
            "--request" if options.request.is_none() => {
                let method = args
                    .next()
                    .ok_or("--request requires a method and JSON parameters")?;
                let raw = args.next().ok_or("--request requires JSON parameters")?;
                if raw.len() > MAX_FRAME_BYTES {
                    return Err("Command is too large".into());
                }
                let params = serde_json::from_str(&raw)?;
                options.request = Some((method, params));
            }
            "--version" => {
                println!("{}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            "--help" | "-h" => {
                println!(
                    "Usage: omarchy-audio-service [--plugin | --socket PATH | --stdio]\n       omarchy-audio-service [--socket PATH] --request METHOD PARAMS_JSON\n       omarchy-audio-service --build-info"
                );
                std::process::exit(0);
            }
            _ => return Err(format!("Unknown or repeated option: {arg}").into()),
        }
    }
    if (options.plugin || options.plugin_daemon)
        && (options.socket.is_some()
            || options.request.is_some()
            || options.stdio
            || (options.plugin && options.plugin_daemon))
    {
        return Err("Plugin modes cannot be combined with other modes".into());
    }
    if options.stdio && (options.socket.is_some() || options.request.is_some()) {
        return Err("--stdio cannot be combined with --socket or --request".into());
    }
    Ok(options)
}
