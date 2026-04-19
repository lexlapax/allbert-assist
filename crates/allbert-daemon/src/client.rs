use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use allbert_kernel::{AllbertPaths, Config};
use allbert_proto::{
    AttachedChannel, ChannelKind, ClientHello, ClientKind, ClientMessage, DaemonStatus,
    ModelConfigPayload, OpenChannel, ProtocolError, ServerMessage, SessionStatus, TurnRequest,
    PROTOCOL_VERSION,
};
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use interprocess::local_socket::{
    prelude::*, tokio::Stream as LocalSocketStream, ConnectOptions, GenericFilePath,
};
use tokio::process::Command;
use tokio::time::{sleep, timeout};
use tokio_util::codec::{Framed, LengthDelimitedCodec};

use crate::error::DaemonError;

type FramedStream = Framed<LocalSocketStream, LengthDelimitedCodec>;

#[derive(Debug, Clone)]
pub struct SpawnConfig {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub allbert_home: PathBuf,
    pub wait_timeout: Duration,
}

impl SpawnConfig {
    pub fn new(program: PathBuf, allbert_home: PathBuf) -> Self {
        Self {
            program,
            args: vec!["run".into()],
            allbert_home,
            wait_timeout: Duration::from_secs(5),
        }
    }
}

pub struct DaemonClient {
    framed: FramedStream,
}

impl DaemonClient {
    pub async fn connect(
        paths: &AllbertPaths,
        client_kind: ClientKind,
    ) -> Result<Self, DaemonError> {
        Self::connect_with_version(paths, client_kind, PROTOCOL_VERSION).await
    }

    pub async fn connect_with_version(
        paths: &AllbertPaths,
        client_kind: ClientKind,
        version: u32,
    ) -> Result<Self, DaemonError> {
        let stream = connect_stream(&paths.daemon_socket).await?;
        let mut framed = Framed::new(stream, LengthDelimitedCodec::new());

        send_message(
            &mut framed,
            &ClientMessage::Hello(ClientHello {
                protocol_version: version,
                client_kind,
            }),
        )
        .await?;

        match recv_message(&mut framed).await? {
            ServerMessage::Hello(_) => Ok(Self { framed }),
            ServerMessage::Error(error) => Err(map_protocol_error(error, version)),
            other => Err(DaemonError::Protocol(format!(
                "expected hello, got {:?}",
                other
            ))),
        }
    }

    pub async fn connect_or_spawn(
        paths: &AllbertPaths,
        client_kind: ClientKind,
        spawn: &SpawnConfig,
    ) -> Result<Self, DaemonError> {
        Self::connect_or_spawn_with(paths, client_kind, spawn.wait_timeout, || async {
            let mut command = Command::new(&spawn.program);
            command
                .args(&spawn.args)
                .env("ALLBERT_HOME", &spawn.allbert_home)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            command.spawn().map_err(|e| {
                DaemonError::Spawn(format!("spawn {}: {e}", spawn.program.display()))
            })?;
            Ok(())
        })
        .await
    }

    pub async fn connect_or_spawn_with<F, Fut>(
        paths: &AllbertPaths,
        client_kind: ClientKind,
        wait_timeout: Duration,
        spawn_once: F,
    ) -> Result<Self, DaemonError>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<(), DaemonError>>,
    {
        if let Ok(client) = Self::connect(paths, client_kind).await {
            return Ok(client);
        }

        spawn_once().await?;

        let connect = async {
            loop {
                match Self::connect(paths, client_kind).await {
                    Ok(client) => return Ok(client),
                    Err(_) => sleep(Duration::from_millis(50)).await,
                }
            }
        };

        timeout(wait_timeout, connect)
            .await
            .map_err(|_| DaemonError::Timeout("daemon auto-spawn"))?
    }

    pub async fn attach(
        &mut self,
        channel: ChannelKind,
        session_id: Option<String>,
    ) -> Result<AttachedChannel, DaemonError> {
        send_message(
            &mut self.framed,
            &ClientMessage::Attach(OpenChannel {
                channel,
                session_id,
            }),
        )
        .await?;

        match recv_message(&mut self.framed).await? {
            ServerMessage::Attached(attached) => Ok(attached),
            ServerMessage::Error(error) => Err(DaemonError::Protocol(error.message)),
            other => Err(DaemonError::Protocol(format!(
                "expected attached, got {:?}",
                other
            ))),
        }
    }

    pub async fn status(&mut self) -> Result<DaemonStatus, DaemonError> {
        self.send(&ClientMessage::Status).await?;
        match self.recv().await? {
            ServerMessage::Status(status) => Ok(status),
            ServerMessage::Error(error) => Err(DaemonError::Protocol(error.message)),
            other => Err(DaemonError::Protocol(format!(
                "expected status, got {:?}",
                other
            ))),
        }
    }

    pub async fn shutdown(&mut self) -> Result<(), DaemonError> {
        self.send(&ClientMessage::Shutdown).await?;
        match self.recv().await? {
            ServerMessage::Ack => Ok(()),
            ServerMessage::Error(error) => Err(DaemonError::Protocol(error.message)),
            other => Err(DaemonError::Protocol(format!(
                "expected ack, got {:?}",
                other
            ))),
        }
    }

    pub async fn session_status(&mut self) -> Result<SessionStatus, DaemonError> {
        self.send(&ClientMessage::SessionStatus).await?;
        match self.recv().await? {
            ServerMessage::SessionStatus(status) => Ok(status),
            ServerMessage::Error(error) => Err(DaemonError::Protocol(error.message)),
            other => Err(DaemonError::Protocol(format!(
                "expected session status, got {:?}",
                other
            ))),
        }
    }

    pub async fn get_model(&mut self) -> Result<ModelConfigPayload, DaemonError> {
        self.send(&ClientMessage::GetModel).await?;
        match self.recv().await? {
            ServerMessage::Model(model) => Ok(model),
            ServerMessage::Error(error) => Err(DaemonError::Protocol(error.message)),
            other => Err(DaemonError::Protocol(format!(
                "expected model, got {:?}",
                other
            ))),
        }
    }

    pub async fn set_model(
        &mut self,
        model: ModelConfigPayload,
    ) -> Result<ModelConfigPayload, DaemonError> {
        self.send(&ClientMessage::SetModel(model)).await?;
        match self.recv().await? {
            ServerMessage::Model(model) => Ok(model),
            ServerMessage::Error(error) => Err(DaemonError::Protocol(error.message)),
            other => Err(DaemonError::Protocol(format!(
                "expected model, got {:?}",
                other
            ))),
        }
    }

    pub async fn reload_session_config(&mut self) -> Result<(), DaemonError> {
        self.send(&ClientMessage::ReloadSessionConfig).await?;
        match self.recv().await? {
            ServerMessage::Ack => Ok(()),
            ServerMessage::Error(error) => Err(DaemonError::Protocol(error.message)),
            other => Err(DaemonError::Protocol(format!(
                "expected ack, got {:?}",
                other
            ))),
        }
    }

    pub async fn start_turn(&mut self, input: String) -> Result<(), DaemonError> {
        self.send(&ClientMessage::RunTurn(TurnRequest { input }))
            .await
    }

    pub async fn send(&mut self, message: &ClientMessage) -> Result<(), DaemonError> {
        send_message(&mut self.framed, message).await
    }

    pub async fn recv(&mut self) -> Result<ServerMessage, DaemonError> {
        recv_message(&mut self.framed).await
    }
}

pub fn default_spawn_config(
    paths: &AllbertPaths,
    config: &Config,
) -> Result<SpawnConfig, DaemonError> {
    let current_exe = std::env::current_exe()
        .map_err(|e| DaemonError::Spawn(format!("resolve current executable: {e}")))?;
    let daemon_program = current_exe
        .parent()
        .map(|dir| dir.join("allbert-daemon"))
        .ok_or_else(|| DaemonError::Spawn("resolve allbert-daemon sibling binary".into()))?;

    let allbert_home = paths.root.clone();
    let mut spawn = SpawnConfig::new(daemon_program, allbert_home);
    if !config.daemon.auto_spawn {
        spawn.wait_timeout = Duration::from_millis(1);
    }
    Ok(spawn)
}

async fn connect_stream(path: &Path) -> Result<LocalSocketStream, DaemonError> {
    let name = path
        .to_fs_name::<GenericFilePath>()
        .map_err(|e| DaemonError::Ipc(e.to_string()))?;
    Ok(ConnectOptions::new().name(name).connect_tokio().await?)
}

async fn send_message(
    framed: &mut FramedStream,
    message: &ClientMessage,
) -> Result<(), DaemonError> {
    let bytes = serde_json::to_vec(message)?;
    framed
        .send(Bytes::from(bytes))
        .await
        .map_err(DaemonError::Io)
}

async fn recv_message(framed: &mut FramedStream) -> Result<ServerMessage, DaemonError> {
    let frame = framed
        .next()
        .await
        .ok_or_else(|| DaemonError::Protocol("connection closed".into()))?
        .map_err(DaemonError::Io)?;
    Ok(serde_json::from_slice(&frame)?)
}

fn map_protocol_error(error: ProtocolError, version: u32) -> DaemonError {
    if error.code == "version_mismatch" {
        DaemonError::VersionMismatch {
            client: version,
            server: PROTOCOL_VERSION,
        }
    } else {
        DaemonError::Protocol(error.message)
    }
}
