use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicU64, AtomicUsize, Ordering},
    Arc,
};

use allbert_kernel::{AllbertPaths, Config};
use allbert_proto::{
    AttachedChannel, ChannelKind, ClientMessage, DaemonStatus, ProtocolError, ServerHello,
    ServerMessage, PROTOCOL_VERSION,
};
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use interprocess::local_socket::{
    prelude::*,
    tokio::{prelude::*, Listener as LocalSocketListener, Stream as LocalSocketStream},
    ConnectOptions, GenericFilePath, ListenerOptions,
};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};
use tokio::{task::JoinHandle, time::Duration};
use tokio_util::{
    codec::{Framed, LengthDelimitedCodec},
    sync::CancellationToken,
};

use crate::error::DaemonError;

type FramedStream = Framed<LocalSocketStream, LengthDelimitedCodec>;

#[derive(Clone)]
struct SharedState {
    daemon_id: String,
    started_at: String,
    socket_path: PathBuf,
    trace_enabled: bool,
    active_clients: Arc<AtomicUsize>,
    next_session: Arc<AtomicU64>,
    shutdown: CancellationToken,
    log_path: PathBuf,
}

pub struct RunningDaemon {
    state: SharedState,
    shutdown: CancellationToken,
    join: JoinHandle<Result<(), DaemonError>>,
}

impl RunningDaemon {
    pub fn socket_path(&self) -> &Path {
        &self.state.socket_path
    }

    pub fn shutdown(&self) {
        self.shutdown.cancel();
    }

    pub async fn wait(self) -> Result<(), DaemonError> {
        self.join
            .await
            .map_err(|e| DaemonError::Protocol(format!("daemon task join failed: {e}")))?
    }
}

pub async fn spawn(config: Config, paths: AllbertPaths) -> Result<RunningDaemon, DaemonError> {
    paths.ensure()?;

    let socket_path = config
        .daemon
        .socket_path
        .clone()
        .unwrap_or_else(|| paths.daemon_socket.clone());
    let log_dir = config
        .daemon
        .log_dir
        .clone()
        .unwrap_or_else(|| paths.logs.clone());
    std::fs::create_dir_all(&log_dir)?;

    prepare_socket_dir(&socket_path)?;
    let listener = bind_listener(&socket_path).await?;

    let shutdown = CancellationToken::new();
    let state = SharedState {
        daemon_id: uuid::Uuid::new_v4().to_string(),
        started_at: now_rfc3339()?,
        socket_path: socket_path.clone(),
        trace_enabled: config.trace,
        active_clients: Arc::new(AtomicUsize::new(0)),
        next_session: Arc::new(AtomicU64::new(1)),
        shutdown: shutdown.clone(),
        log_path: log_dir.join("daemon.log"),
    };
    append_log_line(
        &state.log_path,
        &format!(
            "boot pid={} socket={} trace={}",
            std::process::id(),
            socket_path.display(),
            config.trace
        ),
    )?;

    let run_state = state.clone();
    let join = tokio::spawn(async move { accept_loop(listener, run_state).await });

    Ok(RunningDaemon {
        state,
        shutdown,
        join,
    })
}

async fn bind_listener(socket_path: &Path) -> Result<LocalSocketListener, DaemonError> {
    #[cfg(unix)]
    {
        if socket_path.exists() {
            if try_connect_existing(socket_path).await.is_ok() {
                return Err(DaemonError::AlreadyRunning(socket_path.to_path_buf()));
            }
            std::fs::remove_file(socket_path)?;
        }
    }

    let name = socket_path
        .to_fs_name::<GenericFilePath>()
        .map_err(|e| DaemonError::Ipc(e.to_string()))?;
    let listener = ListenerOptions::new().name(name).create_tokio()?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600))?;
    }

    Ok(listener)
}

async fn try_connect_existing(socket_path: &Path) -> Result<(), DaemonError> {
    let name = socket_path
        .to_fs_name::<GenericFilePath>()
        .map_err(|e| DaemonError::Ipc(e.to_string()))?;
    tokio::time::timeout(
        Duration::from_millis(200),
        ConnectOptions::new().name(name).connect_tokio(),
    )
    .await
    .map_err(|_| DaemonError::Timeout("stale-socket probe"))?
    .map(|_| ())
    .map_err(DaemonError::Io)
}

async fn accept_loop(listener: LocalSocketListener, state: SharedState) -> Result<(), DaemonError> {
    loop {
        tokio::select! {
            _ = state.shutdown.cancelled() => {
                append_log_line(&state.log_path, "shutdown requested")?;
                return Ok(());
            }
            stream = listener.accept() => {
                let stream = stream?;
                let connection_state = state.clone();
                connection_state.active_clients.fetch_add(1, Ordering::SeqCst);
                tokio::spawn(async move {
                    let result = handle_connection(stream, connection_state.clone()).await;
                    connection_state.active_clients.fetch_sub(1, Ordering::SeqCst);
                    if let Err(error) = result {
                        let _ = append_log_line(&connection_state.log_path, &format!("connection error: {error}"));
                    }
                });
            }
        }
    }
}

async fn handle_connection(
    stream: LocalSocketStream,
    state: SharedState,
) -> Result<(), DaemonError> {
    let mut framed = Framed::new(stream, LengthDelimitedCodec::new());

    let hello = recv_client_message(&mut framed).await?;
    match hello {
        ClientMessage::Hello(client) => {
            if client.protocol_version != PROTOCOL_VERSION {
                send_server_message(
                    &mut framed,
                    &ServerMessage::Error(ProtocolError {
                        code: "version_mismatch".into(),
                        message: format!(
                            "client protocol {} does not match daemon protocol {}",
                            client.protocol_version, PROTOCOL_VERSION
                        ),
                    }),
                )
                .await?;
                return Err(DaemonError::VersionMismatch {
                    client: client.protocol_version,
                    server: PROTOCOL_VERSION,
                });
            }

            send_server_message(
                &mut framed,
                &ServerMessage::Hello(ServerHello {
                    protocol_version: PROTOCOL_VERSION,
                    daemon_id: state.daemon_id.clone(),
                    pid: std::process::id(),
                    started_at: state.started_at.clone(),
                }),
            )
            .await?;
        }
        other => {
            send_server_message(
                &mut framed,
                &ServerMessage::Error(ProtocolError {
                    code: "expected_hello".into(),
                    message: format!("expected hello as first message, got {:?}", other),
                }),
            )
            .await?;
            return Err(DaemonError::Protocol("missing initial hello".into()));
        }
    }

    while let Ok(message) = recv_client_message(&mut framed).await {
        match message {
            ClientMessage::Hello(_) => {
                send_server_message(
                    &mut framed,
                    &ServerMessage::Error(ProtocolError {
                        code: "duplicate_hello".into(),
                        message: "hello has already been completed for this connection".into(),
                    }),
                )
                .await?;
            }
            ClientMessage::Attach(open) => {
                let session_id = open.session_id.unwrap_or_else(|| match open.channel {
                    ChannelKind::Repl => ChannelKind::Repl.default_session_id(),
                    ChannelKind::Cli => {
                        format!("cli-{}", state.next_session.fetch_add(1, Ordering::SeqCst))
                    }
                    ChannelKind::Jobs => {
                        format!("jobs-{}", state.next_session.fetch_add(1, Ordering::SeqCst))
                    }
                });

                send_server_message(
                    &mut framed,
                    &ServerMessage::Attached(AttachedChannel {
                        channel: open.channel,
                        session_id,
                    }),
                )
                .await?;
            }
            ClientMessage::Status => {
                send_server_message(
                    &mut framed,
                    &ServerMessage::Status(DaemonStatus {
                        daemon_id: state.daemon_id.clone(),
                        pid: std::process::id(),
                        socket_path: state.socket_path.display().to_string(),
                        started_at: state.started_at.clone(),
                        session_count: state.active_clients.load(Ordering::SeqCst),
                        trace_enabled: state.trace_enabled,
                    }),
                )
                .await?;
            }
            ClientMessage::Shutdown => {
                send_server_message(&mut framed, &ServerMessage::Ack).await?;
                state.shutdown.cancel();
                return Ok(());
            }
        }
    }

    Ok(())
}

fn prepare_socket_dir(socket_path: &Path) -> Result<(), DaemonError> {
    let parent = socket_path.parent().ok_or_else(|| {
        DaemonError::Protocol(format!(
            "socket path {} has no parent",
            socket_path.display()
        ))
    })?;
    std::fs::create_dir_all(parent)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    }

    Ok(())
}

fn now_rfc3339() -> Result<String, DaemonError> {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|e| DaemonError::Protocol(format!("format time: {e}")))
}

fn append_log_line(path: &Path, line: &str) -> Result<(), DaemonError> {
    use std::io::Write;

    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(file, "{line}")?;
    Ok(())
}

async fn send_server_message(
    framed: &mut FramedStream,
    message: &ServerMessage,
) -> Result<(), DaemonError> {
    let bytes = serde_json::to_vec(message)?;
    framed
        .send(Bytes::from(bytes))
        .await
        .map_err(DaemonError::Io)
}

async fn recv_client_message(framed: &mut FramedStream) -> Result<ClientMessage, DaemonError> {
    let frame = framed
        .next()
        .await
        .ok_or_else(|| DaemonError::Protocol("connection closed".into()))?
        .map_err(DaemonError::Io)?;
    Ok(serde_json::from_slice(&frame)?)
}
