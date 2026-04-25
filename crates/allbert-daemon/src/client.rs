use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use allbert_kernel::{AllbertPaths, Config};
use allbert_proto::{
    ActivitySnapshot, AttachedChannel, ChannelKind, ChannelRuntimeStatusPayload, ClientHello,
    ClientKind, ClientMessage, DaemonStatus, InboxApprovalPayload, InboxQueryPayload,
    InboxResolvePayload, InboxResolveResultPayload, JobDefinitionPayload, JobRunRecordPayload,
    JobStatusPayload, ModelConfigPayload, OpenChannel, ProtocolError, ServerMessage,
    SessionResumeEntry, SessionStatus, TelemetrySnapshot, TurnBudgetOverridePayload, TurnRequest,
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
    pub working_dir: Option<PathBuf>,
    pub wait_timeout: Duration,
}

impl SpawnConfig {
    pub fn new(program: PathBuf, allbert_home: PathBuf) -> Self {
        Self {
            program,
            args: vec!["run".into()],
            allbert_home,
            working_dir: None,
            wait_timeout: Duration::from_secs(5),
        }
    }
}

pub struct DaemonClient {
    framed: FramedStream,
    pending: VecDeque<ServerMessage>,
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
            ServerMessage::Hello(_) => Ok(Self {
                framed,
                pending: VecDeque::new(),
            }),
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
                .current_dir(spawn.working_dir.clone().unwrap_or_else(|| {
                    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
                }))
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

        let attached = self
            .recv_expected("attached", |message| match message {
                ServerMessage::Attached(attached) => Some(Ok(attached)),
                ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
                _ => None,
            })
            .await?;
        Ok(attached)
    }

    pub async fn status(&mut self) -> Result<DaemonStatus, DaemonError> {
        self.send(&ClientMessage::Status).await?;
        self.recv_expected("status", |message| match message {
            ServerMessage::Status(status) => Some(Ok(status)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn shutdown(&mut self) -> Result<(), DaemonError> {
        self.send(&ClientMessage::Shutdown).await?;
        self.recv_expected("ack", |message| match message {
            ServerMessage::Ack => Some(Ok(())),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn session_status(&mut self) -> Result<SessionStatus, DaemonError> {
        self.send(&ClientMessage::SessionStatus).await?;
        self.recv_expected("session status", |message| match message {
            ServerMessage::SessionStatus(status) => Some(Ok(status)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn session_telemetry(&mut self) -> Result<TelemetrySnapshot, DaemonError> {
        self.send(&ClientMessage::SessionTelemetry).await?;
        self.recv_expected("session telemetry", |message| match message {
            ServerMessage::SessionTelemetry(telemetry) => Some(Ok(telemetry)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn activity_snapshot(&mut self) -> Result<ActivitySnapshot, DaemonError> {
        self.send(&ClientMessage::ActivitySnapshot).await?;
        self.recv_expected("activity snapshot", |message| match message {
            ServerMessage::ActivitySnapshot(snapshot) => Some(Ok(snapshot)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn list_sessions(&mut self) -> Result<Vec<SessionResumeEntry>, DaemonError> {
        self.send(&ClientMessage::ListSessions).await?;
        self.recv_expected("sessions", |message| match message {
            ServerMessage::Sessions(entries) => Some(Ok(entries)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn list_inbox(
        &mut self,
        identity: Option<String>,
        kind: Option<String>,
        include_resolved: bool,
    ) -> Result<Vec<InboxApprovalPayload>, DaemonError> {
        self.send(&ClientMessage::ListInbox(InboxQueryPayload {
            identity,
            kind,
            include_resolved,
        }))
        .await?;
        self.recv_expected("inbox approvals", |message| match message {
            ServerMessage::InboxApprovals(entries) => Some(Ok(entries)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn show_inbox_approval(
        &mut self,
        approval_id: &str,
    ) -> Result<InboxApprovalPayload, DaemonError> {
        self.send(&ClientMessage::ShowInboxApproval(approval_id.to_string()))
            .await?;
        self.recv_expected("inbox approval", |message| match message {
            ServerMessage::InboxApproval(entry) => Some(Ok(entry)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn resolve_inbox_approval(
        &mut self,
        approval_id: &str,
        accept: bool,
        reason: Option<String>,
    ) -> Result<InboxResolveResultPayload, DaemonError> {
        self.send(&ClientMessage::ResolveInboxApproval(InboxResolvePayload {
            approval_id: approval_id.to_string(),
            accept,
            reason,
        }))
        .await?;
        self.recv_expected("inbox resolution", |message| match message {
            ServerMessage::InboxResolveResult(result) => Some(Ok(result)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn forget_session(&mut self, session_id: &str) -> Result<(), DaemonError> {
        self.send(&ClientMessage::ForgetSession(session_id.to_string()))
            .await?;
        self.recv_expected("ack", |message| match message {
            ServerMessage::Ack => Some(Ok(())),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn get_model(&mut self) -> Result<ModelConfigPayload, DaemonError> {
        self.send(&ClientMessage::GetModel).await?;
        self.recv_expected("model", |message| match message {
            ServerMessage::Model(model) => Some(Ok(model)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn set_model(
        &mut self,
        model: ModelConfigPayload,
    ) -> Result<ModelConfigPayload, DaemonError> {
        self.send(&ClientMessage::SetModel(model)).await?;
        self.recv_expected("model", |message| match message {
            ServerMessage::Model(model) => Some(Ok(model)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn set_cost_override(&mut self, reason: String) -> Result<(), DaemonError> {
        self.send(&ClientMessage::SetCostOverride(reason)).await?;
        self.recv_expected("ack", |message| match message {
            ServerMessage::Ack => Some(Ok(())),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn set_turn_budget_override(
        &mut self,
        usd: Option<f64>,
        seconds: Option<u64>,
    ) -> Result<(), DaemonError> {
        self.send(&ClientMessage::SetTurnBudgetOverride(
            TurnBudgetOverridePayload { usd, seconds },
        ))
        .await?;
        self.recv_expected("ack", |message| match message {
            ServerMessage::Ack => Some(Ok(())),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn reload_session_config(&mut self) -> Result<(), DaemonError> {
        self.send(&ClientMessage::ReloadSessionConfig).await?;
        self.recv_expected("ack", |message| match message {
            ServerMessage::Ack => Some(Ok(())),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn set_auto_confirm(&mut self, enabled: bool) -> Result<(), DaemonError> {
        self.send(&ClientMessage::SetAutoConfirm(enabled)).await?;
        self.recv_expected("ack", |message| match message {
            ServerMessage::Ack => Some(Ok(())),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn set_trace(&mut self, enabled: bool) -> Result<(), DaemonError> {
        self.send(&ClientMessage::SetTrace(enabled)).await?;
        self.recv_expected("ack", |message| match message {
            ServerMessage::Ack => Some(Ok(())),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn list_channel_runtimes(
        &mut self,
    ) -> Result<Vec<ChannelRuntimeStatusPayload>, DaemonError> {
        self.send(&ClientMessage::ListChannelRuntimes).await?;
        self.recv_expected("channel runtimes", |message| match message {
            ServerMessage::ChannelRuntimes(runtimes) => Some(Ok(runtimes)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn start_turn(&mut self, input: String) -> Result<(), DaemonError> {
        self.send(&ClientMessage::RunTurn(TurnRequest { input }))
            .await
    }

    pub async fn list_jobs(&mut self) -> Result<Vec<JobStatusPayload>, DaemonError> {
        self.send(&ClientMessage::ListJobs).await?;
        self.recv_expected("jobs", |message| match message {
            ServerMessage::Jobs(jobs) => Some(Ok(jobs)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn get_job(&mut self, name: &str) -> Result<JobStatusPayload, DaemonError> {
        self.send(&ClientMessage::GetJob(name.to_string())).await?;
        self.recv_expected("job", |message| match message {
            ServerMessage::Job(job) => Some(Ok(job)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn upsert_job(
        &mut self,
        definition: JobDefinitionPayload,
    ) -> Result<JobStatusPayload, DaemonError> {
        self.send(&ClientMessage::UpsertJob(definition)).await?;
        self.recv_expected("job", |message| match message {
            ServerMessage::Job(job) => Some(Ok(job)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn pause_job(&mut self, name: &str) -> Result<JobStatusPayload, DaemonError> {
        self.send(&ClientMessage::PauseJob(name.to_string()))
            .await?;
        self.recv_expected("job", |message| match message {
            ServerMessage::Job(job) => Some(Ok(job)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn resume_job(&mut self, name: &str) -> Result<JobStatusPayload, DaemonError> {
        self.send(&ClientMessage::ResumeJob(name.to_string()))
            .await?;
        self.recv_expected("job", |message| match message {
            ServerMessage::Job(job) => Some(Ok(job)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn run_job(&mut self, name: &str) -> Result<JobRunRecordPayload, DaemonError> {
        self.send(&ClientMessage::RunJob(name.to_string())).await?;
        self.recv_expected("job run", |message| match message {
            ServerMessage::JobRun(run) => Some(Ok(run)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn remove_job(&mut self, name: &str) -> Result<(), DaemonError> {
        self.send(&ClientMessage::RemoveJob(name.to_string()))
            .await?;
        self.recv_expected("ack", |message| match message {
            ServerMessage::Ack => Some(Ok(())),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn sweep_jobs(
        &mut self,
        now: Option<String>,
    ) -> Result<Vec<JobRunRecordPayload>, DaemonError> {
        self.send(&ClientMessage::SweepJobs(now)).await?;
        self.recv_expected("job runs", |message| match message {
            ServerMessage::JobRuns(runs) => Some(Ok(runs)),
            ServerMessage::Error(error) => Some(Err(DaemonError::Protocol(error.message))),
            _ => None,
        })
        .await
    }

    pub async fn send(&mut self, message: &ClientMessage) -> Result<(), DaemonError> {
        send_message(&mut self.framed, message).await
    }

    pub async fn recv(&mut self) -> Result<ServerMessage, DaemonError> {
        if let Some(message) = self.pending.pop_front() {
            return Ok(message);
        }
        recv_message(&mut self.framed).await
    }

    pub fn take_pending_events(&mut self) -> Vec<ServerMessage> {
        let mut pending = Vec::new();
        while let Some(message) = self.pending.pop_front() {
            pending.push(message);
        }
        pending
    }

    async fn recv_expected<T, F>(
        &mut self,
        expected: &str,
        mut classify: F,
    ) -> Result<T, DaemonError>
    where
        F: FnMut(ServerMessage) -> Option<Result<T, DaemonError>>,
    {
        let mut buffered_events = Vec::new();
        loop {
            let message = if let Some(message) = self.pending.pop_front() {
                message
            } else {
                recv_message(&mut self.framed).await?
            };
            if let Some(result) = classify(message.clone()) {
                while let Some(buffered) = buffered_events.pop() {
                    self.pending.push_front(buffered);
                }
                return result;
            }
            match message {
                ServerMessage::Event(_) | ServerMessage::ActivityUpdate(_) => {
                    buffered_events.push(message)
                }
                other => {
                    while let Some(buffered) = buffered_events.pop() {
                        self.pending.push_front(buffered);
                    }
                    return Err(DaemonError::Protocol(format!(
                        "expected {expected}, got {:?}",
                        other
                    )));
                }
            }
        }
    }
}

pub fn default_spawn_config(
    paths: &AllbertPaths,
    config: &Config,
) -> Result<SpawnConfig, DaemonError> {
    let current_exe = std::env::current_exe()
        .map_err(|e| DaemonError::Spawn(format!("resolve current executable: {e}")))?;
    spawn_config_for_executable(&current_exe, paths, config)
}

fn spawn_config_for_executable(
    current_exe: &Path,
    paths: &AllbertPaths,
    config: &Config,
) -> Result<SpawnConfig, DaemonError> {
    let allbert_home = paths.root.clone();
    let mut spawn = if is_cli_binary(current_exe) {
        let mut spawn = SpawnConfig::new(current_exe.to_path_buf(), allbert_home);
        spawn.args = vec!["internal-daemon-host".into()];
        spawn
    } else if let Some(program) = resolve_daemon_binary(current_exe) {
        SpawnConfig::new(program, allbert_home)
    } else if let Some(workspace_root) = find_workspace_root(current_exe) {
        let mut spawn = SpawnConfig::new(PathBuf::from("cargo"), allbert_home);
        spawn.args = vec![
            "run".into(),
            "-q".into(),
            "-p".into(),
            "allbert-daemon".into(),
            "--".into(),
            "run".into(),
        ];
        spawn.working_dir = Some(workspace_root);
        spawn.wait_timeout = Duration::from_secs(20);
        spawn
    } else {
        return Err(DaemonError::Spawn(
            "could not resolve a daemon binary sibling or workspace root for cargo-based auto-spawn".into(),
        ));
    };
    if !config.daemon.auto_spawn {
        spawn.wait_timeout = Duration::from_millis(1);
    }
    Ok(spawn)
}

fn resolve_daemon_binary(current_exe: &Path) -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(parent) = current_exe.parent() {
        candidates.push(parent.join("allbert-daemon"));
        if let Some(grandparent) = parent.parent() {
            candidates.push(grandparent.join("allbert-daemon"));
        }
    }
    candidates.into_iter().find(|candidate| candidate.exists())
}

fn is_cli_binary(current_exe: &Path) -> bool {
    current_exe
        .file_stem()
        .and_then(|stem| stem.to_str())
        .map(|name| name == "allbert-cli")
        .unwrap_or(false)
}

fn find_workspace_root(current_exe: &Path) -> Option<PathBuf> {
    let mut cursor = current_exe.parent();
    while let Some(dir) = cursor {
        if dir.join("Cargo.toml").exists() {
            return Some(dir.to_path_buf());
        }
        cursor = dir.parent();
    }
    None
}

#[cfg(test)]
#[allow(clippy::items_after_test_module)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new() -> Self {
            let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "allbert-daemon-client-test-{}-{}",
                std::process::id(),
                counter
            ));
            std::fs::create_dir_all(&path).expect("temp dir should be created");
            Self { path }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn prefers_self_host_when_running_from_cli_binary() {
        let temp = TempDir::new();
        let paths = AllbertPaths::under(temp.path.join(".allbert"));
        let exe_dir = temp.path.join("target").join("debug");
        std::fs::create_dir_all(&exe_dir).expect("exe dir should exist");
        let current_exe = exe_dir.join("allbert-cli");
        std::fs::write(&current_exe, "").expect("fake cli binary should exist");
        let daemon = exe_dir.join("allbert-daemon");
        std::fs::write(&daemon, "").expect("fake daemon binary should exist");

        let spawn = spawn_config_for_executable(&current_exe, &paths, &Config::default_template())
            .expect("spawn config should resolve");
        assert_eq!(spawn.program, current_exe);
        assert_eq!(spawn.args, vec!["internal-daemon-host".to_string()]);
        assert!(daemon.exists());
    }

    #[test]
    fn falls_back_to_cargo_run_when_only_workspace_root_is_available() {
        let temp = TempDir::new();
        let paths = AllbertPaths::under(temp.path.join(".allbert"));
        std::fs::write(temp.path.join("Cargo.toml"), "[workspace]\n").expect("Cargo.toml");
        let exe_dir = temp.path.join("target").join("debug").join("deps");
        std::fs::create_dir_all(&exe_dir).expect("deps dir should exist");
        let current_exe = exe_dir.join("allbert-cli-hash");
        std::fs::write(&current_exe, "").expect("fake cli binary should exist");

        let spawn = spawn_config_for_executable(&current_exe, &paths, &Config::default_template())
            .expect("spawn config should resolve");
        assert_eq!(spawn.program, PathBuf::from("cargo"));
        assert_eq!(
            spawn.args,
            vec![
                "run".to_string(),
                "-q".to_string(),
                "-p".to_string(),
                "allbert-daemon".to_string(),
                "--".to_string(),
                "run".to_string(),
            ]
        );
        assert_eq!(spawn.working_dir.as_deref(), Some(temp.path.as_path()));
        assert_eq!(spawn.wait_timeout, Duration::from_secs(20));
    }

    #[test]
    fn uses_current_cli_binary_as_hidden_daemon_host_when_sibling_daemon_is_missing() {
        let temp = TempDir::new();
        let paths = AllbertPaths::under(temp.path.join(".allbert"));
        let exe_dir = temp.path.join("target").join("debug");
        std::fs::create_dir_all(&exe_dir).expect("exe dir should exist");
        let current_exe = exe_dir.join("allbert-cli");
        std::fs::write(&current_exe, "").expect("fake cli binary should exist");

        let spawn = spawn_config_for_executable(&current_exe, &paths, &Config::default_template())
            .expect("spawn config should resolve");
        assert_eq!(spawn.program, current_exe);
        assert_eq!(spawn.args, vec!["internal-daemon-host".to_string()]);
        assert!(spawn.working_dir.is_none());
    }
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
