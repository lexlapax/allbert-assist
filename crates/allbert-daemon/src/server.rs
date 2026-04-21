use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    Arc,
};

use allbert_channels::{
    Channel, ChannelCapabilities, ChannelError, ChannelInbound, ChannelOutbound, ConfirmOutcome,
    ConfirmPrompt,
};
use allbert_kernel::{
    job_manager::JobManager as KernelJobManager,
    llm::{ChatMessage, ChatRole},
    llm::{DefaultProviderFactory, ProviderFactory},
    ActiveSkill, ConfirmDecision, ConfirmPrompter, ConfirmRequest, FrontendAdapter, InputPrompter,
    InputRequest, InputResponse, Intent, Kernel, KernelError, KernelEvent, ModelConfig,
    SessionSnapshot,
};
use allbert_kernel::{AllbertPaths, Config};
use allbert_proto::{
    AttachedChannel, ChannelKind, ClientMessage, ConfirmDecisionPayload, ConfirmReplyPayload,
    ConfirmRequestPayload, DaemonStatus, InputReplyPayload, InputRequestPayload,
    InputResponsePayload, KernelEventPayload, ModelConfigPayload, ProtocolError, ProviderKind,
    ServerHello, ServerMessage, SessionResumeEntry, SessionStatus, TurnResult, PROTOCOL_VERSION,
};
use bytes::Bytes;
use chrono::Utc;
use futures_util::{future::join_all, SinkExt, StreamExt};
use interprocess::local_socket::{
    prelude::*,
    tokio::{prelude::*, Listener as LocalSocketListener, Stream as LocalSocketStream},
    ConnectOptions, GenericFilePath, ListenerOptions,
};
use serde::{Deserialize, Serialize};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};
use tokio::{
    sync::{broadcast, mpsc, oneshot, Mutex, RwLock},
    task::JoinHandle,
    time::Duration,
};
use tokio_util::{
    codec::{Framed, LengthDelimitedCodec},
    sync::CancellationToken,
    task::TaskTracker,
};

use crate::error::DaemonError;
use crate::jobs::{execute_job, list_run_records, parse_rfc3339, JobDefinition, JobManager};

type FramedStream = Framed<LocalSocketStream, LengthDelimitedCodec>;

#[derive(Clone)]
struct SharedState {
    daemon_id: String,
    started_at: String,
    socket_path: PathBuf,
    trace_enabled: Arc<AtomicBool>,
    active_clients: Arc<AtomicUsize>,
    next_session: Arc<AtomicU64>,
    next_request: Arc<AtomicU64>,
    shutdown: CancellationToken,
    log_path: PathBuf,
    debug_log_path: PathBuf,
    paths: AllbertPaths,
    default_config: Arc<RwLock<Config>>,
    provider_factory: Arc<dyn ProviderFactory>,
    sessions: Arc<RwLock<HashMap<String, Arc<SessionHandle>>>>,
    job_ephemeral_sessions: Arc<Mutex<HashMap<String, Vec<String>>>>,
    job_manager: Arc<Mutex<JobManager>>,
    notifications: broadcast::Sender<ServerMessage>,
    tasks: Arc<TaskTracker>,
}

struct SessionHandle {
    session_id: String,
    channel: ChannelKind,
    kernel: Arc<Mutex<Kernel>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SessionJournalMeta {
    session_id: String,
    channel: ChannelKind,
    started_at: String,
    last_activity_at: String,
    root_agent_name: String,
    last_agent_stack: Vec<String>,
    last_resolved_intent: Option<String>,
    intent_history: Vec<String>,
    active_skills: Vec<ActiveSkill>,
    ephemeral_memory: Vec<String>,
    model: ModelConfigPayload,
    turn_count: u32,
    cost_total_usd: f64,
    messages: Vec<ChatMessage>,
}

#[derive(Debug, Clone)]
struct SessionJournalSnapshot {
    meta: SessionJournalMeta,
}

#[derive(Debug, Clone)]
struct CompletedTurnRecord {
    user_input: String,
    assistant_text: Option<String>,
    tool_results: Vec<ToolJournalEntry>,
    cost_delta_usd: f64,
}

#[derive(Debug, Clone)]
struct ToolJournalEntry {
    name: String,
    ok: bool,
    content: String,
}

#[derive(Clone)]
struct DaemonJobManager {
    state: SharedState,
}

enum OutboundMessage {
    Event(ServerMessage),
    Confirm(
        ConfirmRequestPayload,
        oneshot::Sender<ConfirmDecisionPayload>,
    ),
    Input(InputRequestPayload, oneshot::Sender<InputResponsePayload>),
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

    pub fn shutdown_handle(&self) -> CancellationToken {
        self.shutdown.clone()
    }

    pub async fn wait(self) -> Result<(), DaemonError> {
        let result = self
            .join
            .await
            .map_err(|e| DaemonError::Protocol(format!("daemon task join failed: {e}")))?;
        self.state.tasks.close();
        if tokio::time::timeout(Duration::from_secs(3), self.state.tasks.wait())
            .await
            .is_err()
        {
            append_log_line(
                &self.state.log_path,
                "shutdown timeout waiting for connection and job tasks",
            )
            .ok();
        }
        #[cfg(unix)]
        if self.state.socket_path.exists() {
            let _ = std::fs::remove_file(&self.state.socket_path);
        }
        result
    }
}

pub async fn spawn(config: Config, paths: AllbertPaths) -> Result<RunningDaemon, DaemonError> {
    spawn_with_factory(config, paths, Arc::new(DefaultProviderFactory::default())).await
}

pub async fn spawn_with_factory(
    config: Config,
    paths: AllbertPaths,
    provider_factory: Arc<dyn ProviderFactory>,
) -> Result<RunningDaemon, DaemonError> {
    paths.ensure()?;
    allbert_kernel::memory::bootstrap_curated_memory(&paths, &config.memory)?;
    archive_expired_sessions(&paths, &config)?;
    let job_manager = JobManager::load(&paths, &config)?;

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
    let (notifications, _) = broadcast::channel(64);
    let state = SharedState {
        daemon_id: uuid::Uuid::new_v4().to_string(),
        started_at: now_rfc3339()?,
        socket_path: socket_path.clone(),
        trace_enabled: Arc::new(AtomicBool::new(config.trace)),
        active_clients: Arc::new(AtomicUsize::new(0)),
        next_session: Arc::new(AtomicU64::new(1)),
        next_request: Arc::new(AtomicU64::new(1)),
        shutdown: shutdown.clone(),
        log_path: log_dir.join("daemon.log"),
        debug_log_path: log_dir.join("daemon.debug.log"),
        paths,
        default_config: Arc::new(RwLock::new(config)),
        provider_factory,
        sessions: Arc::new(RwLock::new(HashMap::new())),
        job_ephemeral_sessions: Arc::new(Mutex::new(HashMap::new())),
        job_manager: Arc::new(Mutex::new(job_manager)),
        notifications,
        tasks: Arc::new(TaskTracker::new()),
    };
    append_log_line(
        &state.log_path,
        &format!(
            "boot pid={} socket={} trace={}",
            std::process::id(),
            socket_path.display(),
            state.trace_enabled.load(Ordering::SeqCst)
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

#[async_trait::async_trait]
impl KernelJobManager for DaemonJobManager {
    async fn list_jobs(&self) -> Result<Vec<allbert_proto::JobStatusPayload>, String> {
        let manager = self.state.job_manager.lock().await;
        Ok(manager.list())
    }

    async fn get_job(&self, name: &str) -> Result<allbert_proto::JobStatusPayload, String> {
        let manager = self.state.job_manager.lock().await;
        manager.get(name).map_err(|err| err.to_string())
    }

    async fn upsert_job(
        &self,
        definition: allbert_proto::JobDefinitionPayload,
    ) -> Result<allbert_proto::JobStatusPayload, String> {
        let defaults = self.state.default_config.read().await.clone();
        let mut manager = self.state.job_manager.lock().await;
        manager
            .upsert(&self.state.paths, &defaults, definition)
            .map_err(|err| err.to_string())
    }

    async fn pause_job(&self, name: &str) -> Result<allbert_proto::JobStatusPayload, String> {
        let mut manager = self.state.job_manager.lock().await;
        manager
            .pause(&self.state.paths, name)
            .map_err(|err| err.to_string())
    }

    async fn resume_job(&self, name: &str) -> Result<allbert_proto::JobStatusPayload, String> {
        let defaults = self.state.default_config.read().await.clone();
        let mut manager = self.state.job_manager.lock().await;
        manager
            .resume(&self.state.paths, &defaults, name, Utc::now())
            .map_err(|err| err.to_string())
    }

    async fn run_job(&self, name: &str) -> Result<allbert_proto::JobRunRecordPayload, String> {
        let defaults = self.state.default_config.read().await.clone();
        run_named_job(&self.state, &defaults, name)
            .await
            .map_err(|err| err.to_string())
    }

    async fn remove_job(&self, name: &str) -> Result<(), String> {
        let mut manager = self.state.job_manager.lock().await;
        manager
            .remove(&self.state.paths, name)
            .map_err(|err| err.to_string())
    }

    async fn list_job_runs(
        &self,
        name: Option<&str>,
        only_failures: bool,
        limit: usize,
    ) -> Result<Vec<allbert_proto::JobRunRecordPayload>, String> {
        list_run_records(&self.state.paths, name, only_failures, limit)
            .map_err(|err| err.to_string())
    }
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
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            _ = state.shutdown.cancelled() => {
                append_log_line(&state.log_path, "shutdown requested")?;
                return Ok(());
            }
            _ = tick.tick() => {
                let defaults = state.default_config.read().await.clone();
                let _ = allbert_kernel::memory::reconcile_curated_memory(&state.paths, &defaults.memory);
                if defaults.jobs.enabled {
                    let _ = run_due_jobs(&state, &defaults, Utc::now()).await;
                }
            }
            stream = listener.accept() => {
                let stream = stream?;
                let connection_state = state.clone();
                connection_state.active_clients.fetch_add(1, Ordering::SeqCst);
                state.tasks.spawn(async move {
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
    let mut notifications = state.notifications.subscribe();

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

    let mut attached_session: Option<Arc<SessionHandle>> = None;

    loop {
        let message = if attached_session.is_some() {
            tokio::select! {
                _ = state.shutdown.cancelled() => return Ok(()),
                notification = notifications.recv() => {
                    match notification {
                        Ok(message) => {
                            send_server_message(&mut framed, &message).await?;
                            continue;
                        }
                        Err(broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(broadcast::error::RecvError::Closed) => continue,
                    }
                }
                message = recv_client_message(&mut framed) => match message {
                    Ok(message) => message,
                    Err(_) => return Ok(()),
                }
            }
        } else {
            tokio::select! {
                _ = state.shutdown.cancelled() => return Ok(()),
                message = recv_client_message(&mut framed) => match message {
                    Ok(message) => message,
                    Err(_) => return Ok(()),
                }
            }
        };
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
                    ChannelKind::Telegram => format!(
                        "telegram-{}",
                        state.next_session.fetch_add(1, Ordering::SeqCst)
                    ),
                });

                let session = get_or_create_session(&state, open.channel, session_id).await?;
                let attached = AttachedChannel {
                    channel: session.channel,
                    session_id: session.session_id.clone(),
                };
                append_debug_line(
                    &state,
                    &format!(
                        "attach channel={:?} session={}",
                        attached.channel, attached.session_id
                    ),
                )
                .ok();
                attached_session = Some(session);
                send_server_message(&mut framed, &ServerMessage::Attached(attached)).await?;
            }
            ClientMessage::Status => {
                send_server_message(
                    &mut framed,
                    &ServerMessage::Status(DaemonStatus {
                        daemon_id: state.daemon_id.clone(),
                        pid: std::process::id(),
                        socket_path: state.socket_path.display().to_string(),
                        started_at: state.started_at.clone(),
                        session_count: state.sessions.read().await.len(),
                        trace_enabled: state.trace_enabled.load(Ordering::SeqCst),
                    }),
                )
                .await?;
            }
            ClientMessage::SessionStatus => {
                let session = require_session(attached_session.as_ref())?;
                let status = session_status(&state, session).await?;
                send_server_message(&mut framed, &ServerMessage::SessionStatus(status)).await?;
            }
            ClientMessage::ListSessions => {
                let config = state.default_config.read().await.clone();
                let sessions = list_resumable_sessions(&state.paths, &config)?;
                send_server_message(&mut framed, &ServerMessage::Sessions(sessions)).await?;
            }
            ClientMessage::ForgetSession(session_id) => {
                if state.sessions.read().await.contains_key(&session_id) {
                    send_server_message(
                        &mut framed,
                        &ServerMessage::Error(ProtocolError {
                            code: "session_active".into(),
                            message: format!("cannot forget active session: {session_id}"),
                        }),
                    )
                    .await?;
                    continue;
                }
                forget_session_dir(&state.paths, &session_id)?;
                send_server_message(&mut framed, &ServerMessage::Ack).await?;
            }
            ClientMessage::GetModel => {
                let session = require_session(attached_session.as_ref())?;
                let kernel = session.kernel.lock().await;
                send_server_message(
                    &mut framed,
                    &ServerMessage::Model(model_to_payload(kernel.model())),
                )
                .await?;
            }
            ClientMessage::SetModel(model) => {
                let session = require_session(attached_session.as_ref())?;
                let mut kernel = session.kernel.lock().await;
                kernel
                    .set_model(model_from_payload(model.clone()))
                    .await
                    .map_err(map_kernel_error)?;
                persist_kernel_session(&state.paths, session.channel, &kernel)
                    .map_err(map_kernel_error)?;
                send_server_message(
                    &mut framed,
                    &ServerMessage::Model(model_to_payload(kernel.model())),
                )
                .await?;
            }
            ClientMessage::SetCostOverride(reason) => {
                let session = require_session(attached_session.as_ref())?;
                let mut kernel = session.kernel.lock().await;
                kernel.set_cost_override(reason);
                send_server_message(&mut framed, &ServerMessage::Ack).await?;
            }
            ClientMessage::SetAutoConfirm(enabled) => {
                let session = require_session(attached_session.as_ref())?;
                let mut kernel = session.kernel.lock().await;
                let mut session_config = kernel.config().clone();
                session_config.security.auto_confirm = enabled;
                kernel
                    .apply_config(session_config)
                    .await
                    .map_err(map_kernel_error)?;
                append_debug_line(
                    &state,
                    &format!("session={} auto_confirm={enabled}", session.session_id),
                )?;
                send_server_message(&mut framed, &ServerMessage::Ack).await?;
            }
            ClientMessage::SetTrace(enabled) => {
                state.trace_enabled.store(enabled, Ordering::SeqCst);
                {
                    let mut config = state.default_config.write().await;
                    config.trace = enabled;
                }
                append_debug_line(&state, &format!("trace={enabled}")).ok();
                send_server_message(&mut framed, &ServerMessage::Ack).await?;
            }
            ClientMessage::ReloadSessionConfig => {
                let session = require_session(attached_session.as_ref())?;
                let reloaded = Config::load_or_create(&state.paths).map_err(map_kernel_error)?;
                *state.default_config.write().await = reloaded.clone();
                {
                    let mut manager = state.job_manager.lock().await;
                    manager.reload(&state.paths, &reloaded)?;
                }
                let mut kernel = session.kernel.lock().await;
                let session_model = kernel.model().clone();
                let mut session_config = reloaded;
                session_config.model = session_model;
                kernel
                    .apply_config(session_config)
                    .await
                    .map_err(map_kernel_error)?;
                persist_kernel_session(&state.paths, session.channel, &kernel)
                    .map_err(map_kernel_error)?;
                send_server_message(&mut framed, &ServerMessage::Ack).await?;
            }
            ClientMessage::ListJobs => {
                let manager = state.job_manager.lock().await;
                send_server_message(&mut framed, &ServerMessage::Jobs(manager.list())).await?;
            }
            ClientMessage::GetJob(name) => {
                let manager = state.job_manager.lock().await;
                let job = manager.get(&name)?;
                send_server_message(&mut framed, &ServerMessage::Job(job)).await?;
            }
            ClientMessage::UpsertJob(definition) => {
                let defaults = state.default_config.read().await.clone();
                let mut manager = state.job_manager.lock().await;
                let job = manager.upsert(&state.paths, &defaults, definition)?;
                send_server_message(&mut framed, &ServerMessage::Job(job)).await?;
            }
            ClientMessage::PauseJob(name) => {
                let mut manager = state.job_manager.lock().await;
                let job = manager.pause(&state.paths, &name)?;
                send_server_message(&mut framed, &ServerMessage::Job(job)).await?;
            }
            ClientMessage::ResumeJob(name) => {
                let defaults = state.default_config.read().await.clone();
                let mut manager = state.job_manager.lock().await;
                let job = manager.resume(&state.paths, &defaults, &name, Utc::now())?;
                send_server_message(&mut framed, &ServerMessage::Job(job)).await?;
            }
            ClientMessage::RunJob(name) => {
                let defaults = state.default_config.read().await.clone();
                let run = run_named_job(&state, &defaults, &name).await?;
                send_server_message(&mut framed, &ServerMessage::JobRun(run)).await?;
            }
            ClientMessage::RemoveJob(name) => {
                let mut manager = state.job_manager.lock().await;
                manager.remove(&state.paths, &name)?;
                send_server_message(&mut framed, &ServerMessage::Ack).await?;
            }
            ClientMessage::SweepJobs(now) => {
                let sweep_at = match now {
                    Some(value) => parse_rfc3339(&value)?,
                    None => Utc::now(),
                };
                let defaults = state.default_config.read().await.clone();
                let runs = run_due_jobs(&state, &defaults, sweep_at).await?;
                send_server_message(&mut framed, &ServerMessage::JobRuns(runs)).await?;
            }
            ClientMessage::RunTurn(turn) => {
                let session = require_session(attached_session.as_ref())?.clone();
                run_turn_over_channel(&mut framed, &state, &mut notifications, session, turn.input)
                    .await?;
            }
            ClientMessage::ConfirmReply(_)
            | ClientMessage::InputReply(_)
            | ClientMessage::Shutdown => match message {
                ClientMessage::Shutdown => {
                    send_server_message(&mut framed, &ServerMessage::Ack).await?;
                    state.shutdown.cancel();
                    return Ok(());
                }
                _ => {
                    send_server_message(
                        &mut framed,
                        &ServerMessage::Error(ProtocolError {
                            code: "unexpected_reply".into(),
                            message: "unexpected interactive reply outside a pending turn".into(),
                        }),
                    )
                    .await?;
                }
            },
        }
    }
}

async fn get_or_create_session(
    state: &SharedState,
    channel: ChannelKind,
    session_id: String,
) -> Result<Arc<SessionHandle>, DaemonError> {
    if let Some(existing) = state.sessions.read().await.get(&session_id).cloned() {
        return Ok(existing);
    }

    let adapter = disconnected_adapter();
    let config = state.default_config.read().await.clone();
    let mut kernel = Kernel::boot_with_paths_and_factory(
        config,
        adapter,
        state.paths.clone(),
        state.provider_factory.clone(),
        Some(session_id.clone()),
    )
    .await
    .map_err(map_kernel_error)?;
    if let Some(snapshot) = load_session_snapshot(&state.paths, &session_id)? {
        kernel
            .restore_session_snapshot(snapshot_to_kernel(snapshot.meta))
            .await
            .map_err(map_kernel_error)?;
    } else {
        persist_kernel_session(&state.paths, channel, &kernel).map_err(map_kernel_error)?;
    }
    kernel.register_job_manager(Arc::new(DaemonJobManager {
        state: state.clone(),
    }));
    let handle = Arc::new(SessionHandle {
        session_id: session_id.clone(),
        channel,
        kernel: Arc::new(Mutex::new(kernel)),
    });

    let mut sessions = state.sessions.write().await;
    Ok(sessions
        .entry(session_id)
        .or_insert_with(|| handle.clone())
        .clone())
}

async fn run_named_job(
    state: &SharedState,
    defaults: &Config,
    name: &str,
) -> Result<allbert_proto::JobRunRecordPayload, DaemonError> {
    let definition = {
        let mut manager = state.job_manager.lock().await;
        manager.prepare_run_now(defaults, name)?
    };

    let mut runs = execute_planned_jobs(state, defaults, vec![definition]).await?;
    runs.pop()
        .ok_or_else(|| DaemonError::Protocol(format!("job run did not complete: {name}")))
}

async fn run_due_jobs(
    state: &SharedState,
    defaults: &Config,
    now: chrono::DateTime<Utc>,
) -> Result<Vec<allbert_proto::JobRunRecordPayload>, DaemonError> {
    let planned = {
        let mut manager = state.job_manager.lock().await;
        manager.plan_due_runs(&state.paths, defaults, now)?
    };
    execute_planned_jobs(state, defaults, planned).await
}

async fn execute_planned_jobs(
    state: &SharedState,
    defaults: &Config,
    planned: Vec<JobDefinition>,
) -> Result<Vec<allbert_proto::JobRunRecordPayload>, DaemonError> {
    if planned.is_empty() {
        return Ok(Vec::new());
    }

    let futures = planned.into_iter().map(|definition| {
        let paths = state.paths.clone();
        let defaults = defaults.clone();
        let provider_factory = state.provider_factory.clone();
        let job_ephemeral_sessions = state.job_ephemeral_sessions.clone();
        let shutdown = state.shutdown.clone();
        async move {
            let name = definition.name.clone();
            let record = execute_job(
                &paths,
                &defaults,
                provider_factory,
                job_ephemeral_sessions,
                shutdown,
                &definition,
            )
            .await;
            (name, record)
        }
    });

    let results = join_all(futures).await;
    let mut manager = state.job_manager.lock().await;
    let mut completed = Vec::with_capacity(results.len());
    for (name, record) in results {
        let finished = manager.finish_run(&state.paths, defaults, &name, record)?;
        if finished.outcome != "success" {
            let _ = state
                .notifications
                .send(ServerMessage::Event(KernelEventPayload::JobFailed {
                    job_name: finished.job_name.clone(),
                    run_id: finished.run_id.clone(),
                    ended_at: finished.ended_at.clone(),
                    stop_reason: finished.stop_reason.clone(),
                }));
        }
        completed.push(finished);
    }
    Ok(completed)
}

async fn run_turn_over_channel(
    framed: &mut FramedStream,
    state: &SharedState,
    notifications: &mut broadcast::Receiver<ServerMessage>,
    session: Arc<SessionHandle>,
    input: String,
) -> Result<(), DaemonError> {
    append_debug_line(
        state,
        &format!(
            "run_turn session={} input_len={}",
            session.session_id,
            input.len()
        ),
    )
    .ok();
    let (pre_turn_messages, pre_turn_cost) = {
        let kernel = session.kernel.lock().await;
        let snapshot = kernel.export_session_snapshot();
        (snapshot.messages.len(), snapshot.cost_total_usd)
    };
    let turn_input = input.clone();
    let (tx, mut rx) = mpsc::unbounded_channel();
    let local_channel = LocalIpcChannel::new(session.channel, tx, state.next_request.clone());
    let adapter = channel_adapter(local_channel);

    let kernel = session.kernel.clone();
    let turn = async move {
        let mut kernel = kernel.lock().await;
        kernel.set_adapter(adapter);
        kernel.run_turn(&turn_input).await
    };
    tokio::pin!(turn);

    let mut client_connected = true;
    let mut tool_results = Vec::new();

    loop {
        tokio::select! {
            _ = state.shutdown.cancelled() => {
                if client_connected {
                    let _ = send_server_message(
                        framed,
                        &ServerMessage::Error(ProtocolError {
                            code: "daemon_shutdown".into(),
                            message: "daemon shutdown interrupted the active turn".into(),
                        }),
                    )
                    .await;
                }
                return Ok(());
            }
            notification = notifications.recv() => {
                match notification {
                    Ok(message) => {
                        if client_connected && send_server_message(framed, &message).await.is_err() {
                            client_connected = false;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => {}
                }
            }
            outbound = rx.recv() => {
                let Some(outbound) = outbound else {
                    continue;
                };
                match outbound {
                    OutboundMessage::Event(message) => {
                        if let ServerMessage::Event(KernelEventPayload::ToolResult { name, ok, content }) = &message {
                            tool_results.push(ToolJournalEntry {
                                name: name.clone(),
                                ok: *ok,
                                content: truncate_tool_output(content, state.default_config.read().await.memory.max_journal_tool_output_bytes),
                            });
                        }
                        if client_connected && send_server_message(framed, &message).await.is_err() {
                            client_connected = false;
                        }
                    }
                    OutboundMessage::Confirm(request, reply) => {
                        if !client_connected {
                            let _ = reply.send(ConfirmDecisionPayload::Deny);
                            continue;
                        }
                        if send_server_message(framed, &ServerMessage::ConfirmRequest(request.clone())).await.is_err() {
                            client_connected = false;
                            let _ = reply.send(ConfirmDecisionPayload::Deny);
                            continue;
                        }
                        match recv_client_message(framed).await {
                            Ok(ClientMessage::ConfirmReply(ConfirmReplyPayload { request_id, decision })) if request_id == request.request_id => {
                                let _ = reply.send(decision);
                            }
                            Ok(_) | Err(_) => {
                                client_connected = false;
                                let _ = reply.send(ConfirmDecisionPayload::Deny);
                            }
                        }
                    }
                    OutboundMessage::Input(request, reply) => {
                        if !client_connected {
                            let _ = reply.send(InputResponsePayload::Cancelled);
                            continue;
                        }
                        if send_server_message(framed, &ServerMessage::InputRequest(request.clone())).await.is_err() {
                            client_connected = false;
                            let _ = reply.send(InputResponsePayload::Cancelled);
                            continue;
                        }
                        match recv_client_message(framed).await {
                            Ok(ClientMessage::InputReply(InputReplyPayload { request_id, response })) if request_id == request.request_id => {
                                let _ = reply.send(response);
                            }
                            Ok(_) | Err(_) => {
                                client_connected = false;
                                let _ = reply.send(InputResponsePayload::Cancelled);
                            }
                        }
                    }
                }
            }
            result = &mut turn => {
                match result {
                    Ok(summary) => {
                        drain_outbound_queue(
                            &mut rx,
                            framed,
                            &mut client_connected,
                            &mut tool_results,
                            state.default_config.read().await.memory.max_journal_tool_output_bytes,
                        )
                        .await;
                        {
                            let kernel = session.kernel.lock().await;
                            persist_completed_turn(
                                &state.paths,
                                session.channel,
                                &kernel,
                                CompletedTurnRecord {
                                    user_input: input.clone(),
                                    assistant_text: extract_turn_assistant_text(&kernel, pre_turn_messages),
                                    tool_results,
                                    cost_delta_usd: (kernel.session_cost_usd() - pre_turn_cost).max(0.0),
                                },
                            )
                            .map_err(map_kernel_error)?;
                        }
                        if client_connected {
                            let _ = send_server_message(
                                framed,
                                &ServerMessage::TurnResult(TurnResult {
                                    hit_turn_limit: summary.hit_turn_limit,
                                }),
                            )
                            .await;
                        }
                        return Ok(());
                    }
                    Err(error) => {
                        drain_outbound_queue(
                            &mut rx,
                            framed,
                            &mut client_connected,
                            &mut tool_results,
                            state.default_config.read().await.memory.max_journal_tool_output_bytes,
                        )
                        .await;
                        append_log_line(
                            &state.log_path,
                            &format!(
                                "session {} turn interrupted before completion boundary: {error}",
                                session.session_id
                            ),
                        )
                        .ok();
                        if client_connected {
                            let _ = send_server_message(
                                framed,
                                &ServerMessage::Error(ProtocolError {
                                    code: "turn_failed".into(),
                                    message: error.to_string(),
                                }),
                            )
                            .await;
                        }
                        return Ok(());
                    }
                }
            }
        }
    }
}

async fn drain_outbound_queue(
    rx: &mut mpsc::UnboundedReceiver<OutboundMessage>,
    framed: &mut FramedStream,
    client_connected: &mut bool,
    tool_results: &mut Vec<ToolJournalEntry>,
    max_journal_tool_output_bytes: usize,
) {
    while let Ok(outbound) = rx.try_recv() {
        match outbound {
            OutboundMessage::Event(message) => {
                if let ServerMessage::Event(KernelEventPayload::ToolResult { name, ok, content }) =
                    &message
                {
                    tool_results.push(ToolJournalEntry {
                        name: name.clone(),
                        ok: *ok,
                        content: truncate_tool_output(content, max_journal_tool_output_bytes),
                    });
                }
                if *client_connected && send_server_message(framed, &message).await.is_err() {
                    *client_connected = false;
                }
            }
            OutboundMessage::Confirm(_, reply) => {
                let _ = reply.send(ConfirmDecisionPayload::Deny);
            }
            OutboundMessage::Input(_, reply) => {
                let _ = reply.send(InputResponsePayload::Cancelled);
            }
        }
    }
}

fn require_session(
    session: Option<&Arc<SessionHandle>>,
) -> Result<&Arc<SessionHandle>, DaemonError> {
    session.ok_or_else(|| DaemonError::Protocol("no session is attached to this connection".into()))
}

async fn session_status(
    state: &SharedState,
    session: &Arc<SessionHandle>,
) -> Result<SessionStatus, DaemonError> {
    let kernel = session.kernel.lock().await;
    let config = kernel.config().clone();
    let model = kernel.model().clone();

    Ok(SessionStatus {
        session_id: session.session_id.clone(),
        provider: kernel.provider_name().into(),
        model: model_to_payload(&model),
        api_key_present: std::env::var_os(&model.api_key_env).is_some(),
        setup_version: config.setup.version,
        bootstrap_pending: kernel.paths().bootstrap.exists(),
        trusted_roots: config
            .security
            .fs_roots
            .iter()
            .map(|path| path.display().to_string())
            .collect(),
        skill_count: kernel.list_skills().len(),
        trace_enabled: state.trace_enabled.load(Ordering::SeqCst),
        session_cost_usd: kernel.session_cost_usd(),
        today_cost_usd: kernel.today_cost_usd().map_err(map_kernel_error)?,
        root_agent_name: kernel.agent_name().to_string(),
        last_agent_stack: kernel.last_agent_stack().to_vec(),
        last_resolved_intent: kernel
            .last_resolved_intent()
            .map(|intent| intent.as_str().to_string()),
    })
}

fn session_dir(paths: &AllbertPaths, session_id: &str) -> PathBuf {
    paths.sessions.join(session_id)
}

fn session_meta_path(paths: &AllbertPaths, session_id: &str) -> PathBuf {
    session_dir(paths, session_id).join("meta.json")
}

fn session_turns_path(paths: &AllbertPaths, session_id: &str) -> PathBuf {
    session_dir(paths, session_id).join("turns.md")
}

fn snapshot_to_kernel(meta: SessionJournalMeta) -> SessionSnapshot {
    SessionSnapshot {
        session_id: meta.session_id,
        root_agent_name: meta.root_agent_name,
        messages: meta.messages,
        active_skills: meta.active_skills,
        turn_count: meta.turn_count,
        cost_total_usd: meta.cost_total_usd,
        last_resolved_intent: meta.last_resolved_intent.as_deref().and_then(Intent::parse),
        last_agent_stack: meta.last_agent_stack,
        ephemeral_memory: meta.ephemeral_memory,
        model: model_from_payload(meta.model),
    }
}

fn build_session_meta(
    channel: ChannelKind,
    kernel: &Kernel,
    started_at: String,
    last_activity_at: String,
    prior_intents: &[String],
) -> SessionJournalMeta {
    let snapshot = kernel.export_session_snapshot();
    let mut intent_history = prior_intents.to_vec();
    if let Some(intent) = snapshot
        .last_resolved_intent
        .as_ref()
        .map(Intent::as_str)
        .map(str::to_string)
    {
        if intent_history.last() != Some(&intent) {
            intent_history.push(intent);
        }
    }
    SessionJournalMeta {
        session_id: snapshot.session_id,
        channel,
        started_at,
        last_activity_at,
        root_agent_name: snapshot.root_agent_name,
        last_agent_stack: snapshot.last_agent_stack,
        last_resolved_intent: snapshot
            .last_resolved_intent
            .as_ref()
            .map(Intent::as_str)
            .map(str::to_string),
        intent_history,
        active_skills: snapshot.active_skills,
        ephemeral_memory: snapshot.ephemeral_memory,
        model: model_to_payload(&snapshot.model),
        turn_count: snapshot.turn_count,
        cost_total_usd: snapshot.cost_total_usd,
        messages: snapshot.messages,
    }
}

fn persist_kernel_session(
    paths: &AllbertPaths,
    channel: ChannelKind,
    kernel: &Kernel,
) -> Result<(), KernelError> {
    let session_id = kernel.session_id().to_string();
    let existing = load_session_snapshot(paths, &session_id).map_err(|err| {
        KernelError::InitFailed(format!("load session snapshot for {session_id}: {err}"))
    })?;
    let started_at = existing
        .as_ref()
        .map(|snapshot| snapshot.meta.started_at.clone())
        .unwrap_or_else(now_rfc3339_fallback);
    let prior_intents = existing
        .as_ref()
        .map(|snapshot| snapshot.meta.intent_history.clone())
        .unwrap_or_default();
    persist_session_meta(
        paths,
        &build_session_meta(
            channel,
            kernel,
            started_at,
            now_rfc3339_fallback(),
            &prior_intents,
        ),
    )
}

fn persist_completed_turn(
    paths: &AllbertPaths,
    channel: ChannelKind,
    kernel: &Kernel,
    record: CompletedTurnRecord,
) -> Result<(), KernelError> {
    let session_id = kernel.session_id().to_string();
    let existing = load_session_snapshot(paths, &session_id).map_err(|err| {
        KernelError::InitFailed(format!("load session snapshot for {session_id}: {err}"))
    })?;
    let started_at = existing
        .as_ref()
        .map(|snapshot| snapshot.meta.started_at.clone())
        .unwrap_or_else(now_rfc3339_fallback);
    let prior_intents = existing
        .as_ref()
        .map(|snapshot| snapshot.meta.intent_history.clone())
        .unwrap_or_default();
    let meta = build_session_meta(
        channel,
        kernel,
        started_at,
        now_rfc3339_fallback(),
        &prior_intents,
    );
    persist_session_meta(paths, &meta)?;
    append_turn_record(paths, &meta.session_id, &record).map_err(|err| {
        KernelError::InitFailed(format!(
            "append session journal for {}: {err}",
            meta.session_id
        ))
    })?;
    Ok(())
}

fn persist_session_meta(
    paths: &AllbertPaths,
    meta: &SessionJournalMeta,
) -> Result<(), KernelError> {
    let dir = session_dir(paths, &meta.session_id);
    fs::create_dir_all(&dir)
        .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", dir.display())))?;
    let rendered = serde_json::to_vec_pretty(meta)
        .map_err(|e| KernelError::InitFailed(format!("serialize session meta: {e}")))?;
    fs::write(session_meta_path(paths, &meta.session_id), rendered).map_err(|e| {
        KernelError::InitFailed(format!(
            "write {}: {e}",
            session_meta_path(paths, &meta.session_id).display()
        ))
    })?;
    let turns = session_turns_path(paths, &meta.session_id);
    if !turns.exists() {
        fs::write(
            &turns,
            format!(
                "# Session {}\n\n- channel: {:?}\n- started_at: {}\n\n",
                meta.session_id, meta.channel, meta.started_at
            ),
        )
        .map_err(|e| KernelError::InitFailed(format!("write {}: {e}", turns.display())))?;
    }
    Ok(())
}

fn append_turn_record(
    paths: &AllbertPaths,
    session_id: &str,
    record: &CompletedTurnRecord,
) -> Result<(), std::io::Error> {
    let path = session_turns_path(paths, session_id);
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(file, "## {}", now_rfc3339_fallback())?;
    writeln!(file, "- cost_delta_usd: {:.6}", record.cost_delta_usd)?;
    writeln!(file)?;
    writeln!(file, "### user")?;
    writeln!(file)?;
    writeln!(file, "{}", record.user_input.trim())?;
    writeln!(file)?;
    for tool in &record.tool_results {
        writeln!(file, "### tool `{}` (ok={})", tool.name, tool.ok)?;
        writeln!(file)?;
        writeln!(file, "{}", tool.content.trim())?;
        writeln!(file)?;
    }
    if let Some(text) = &record.assistant_text {
        writeln!(file, "### assistant")?;
        writeln!(file)?;
        writeln!(file, "{}", text.trim())?;
        writeln!(file)?;
    }
    Ok(())
}

fn extract_turn_assistant_text(kernel: &Kernel, pre_turn_messages: usize) -> Option<String> {
    let snapshot = kernel.export_session_snapshot();
    snapshot
        .messages
        .iter()
        .skip(pre_turn_messages)
        .rev()
        .find_map(|message| match message.role {
            ChatRole::Assistant => Some(message.content.clone()),
            ChatRole::User => None,
        })
}

fn truncate_tool_output(content: &str, limit: usize) -> String {
    if content.as_bytes().len() <= limit {
        return content.to_string();
    }
    let mut end = 0usize;
    for (idx, ch) in content.char_indices() {
        let next = idx + ch.len_utf8();
        if next > limit {
            break;
        }
        end = next;
    }
    format!("{}…", &content[..end])
}

fn load_session_snapshot(
    paths: &AllbertPaths,
    session_id: &str,
) -> Result<Option<SessionJournalSnapshot>, DaemonError> {
    let meta_path = session_meta_path(paths, session_id);
    if !meta_path.exists() {
        return Ok(None);
    }
    let raw = fs::read(&meta_path)?;
    let meta: SessionJournalMeta = serde_json::from_slice(&raw)?;
    Ok(Some(SessionJournalSnapshot { meta }))
}

fn list_resumable_sessions(
    paths: &AllbertPaths,
    config: &Config,
) -> Result<Vec<SessionResumeEntry>, DaemonError> {
    archive_expired_sessions(paths, config)?;
    let mut entries = Vec::new();
    for entry in fs::read_dir(&paths.sessions)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        let session_id = name.to_string_lossy().to_string();
        if let Some(snapshot) = load_session_snapshot(paths, &session_id)? {
            entries.push(SessionResumeEntry {
                session_id: snapshot.meta.session_id,
                channel: snapshot.meta.channel,
                started_at: snapshot.meta.started_at,
                last_activity_at: snapshot.meta.last_activity_at,
                turn_count: snapshot.meta.turn_count,
            });
        }
    }
    entries.sort_by(|a, b| b.last_activity_at.cmp(&a.last_activity_at));
    Ok(entries)
}

fn archive_expired_sessions(paths: &AllbertPaths, config: &Config) -> Result<(), DaemonError> {
    let max_age_days = i64::from(config.daemon.session_max_age_days);
    if max_age_days <= 0 {
        return Ok(());
    }
    let cutoff = OffsetDateTime::now_utc() - time::Duration::days(max_age_days);
    for entry in fs::read_dir(&paths.sessions)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        let session_id = name.to_string_lossy().to_string();
        let Some(snapshot) = load_session_snapshot(paths, &session_id)? else {
            continue;
        };
        let last_activity = OffsetDateTime::parse(&snapshot.meta.last_activity_at, &Rfc3339)
            .unwrap_or_else(|_| OffsetDateTime::now_utc());
        if last_activity >= cutoff {
            continue;
        }
        let destination = paths.sessions_archive.join(&session_id);
        if destination.exists() {
            let _ = fs::remove_dir_all(&destination);
        }
        fs::rename(session_dir(paths, &session_id), destination)?;
    }
    Ok(())
}

fn forget_session_dir(paths: &AllbertPaths, session_id: &str) -> Result<(), DaemonError> {
    let source = session_dir(paths, session_id);
    if !source.exists() {
        return Err(DaemonError::Protocol(format!(
            "session not found: {session_id}"
        )));
    }
    let destination = paths.sessions_trash.join(session_id);
    if destination.exists() {
        fs::remove_dir_all(&destination)?;
    }
    fs::rename(source, destination)?;
    Ok(())
}

fn now_rfc3339_fallback() -> String {
    now_rfc3339().unwrap_or_else(|_| Utc::now().to_rfc3339())
}

fn disconnected_adapter() -> FrontendAdapter {
    FrontendAdapter {
        on_event: Box::new(|_| {}),
        confirm: Arc::new(DisconnectedConfirm),
        input: Arc::new(DisconnectedInput),
    }
}

fn channel_adapter(
    channel: Arc<LocalIpcChannel>,
) -> FrontendAdapter {
    let channel_for_events = channel.clone();
    FrontendAdapter {
        on_event: Box::new(move |event: &KernelEvent| {
            let _ = channel_for_events.emit_kernel_event(event);
        }),
        confirm: channel.clone(),
        input: channel,
    }
}

struct DisconnectedConfirm;

#[async_trait::async_trait]
impl ConfirmPrompter for DisconnectedConfirm {
    async fn confirm(&self, _req: ConfirmRequest) -> ConfirmDecision {
        ConfirmDecision::Deny
    }
}

struct DisconnectedInput;

#[async_trait::async_trait]
impl InputPrompter for DisconnectedInput {
    async fn request_input(&self, _req: InputRequest) -> InputResponse {
        InputResponse::Cancelled
    }
}

struct LocalIpcChannel {
    kind: ChannelKind,
    capabilities: ChannelCapabilities,
    outbound: mpsc::UnboundedSender<OutboundMessage>,
    next_request: Arc<AtomicU64>,
}

impl LocalIpcChannel {
    fn new(
        kind: ChannelKind,
        outbound: mpsc::UnboundedSender<OutboundMessage>,
        next_request: Arc<AtomicU64>,
    ) -> Arc<Self> {
        Arc::new(Self {
            kind,
            capabilities: ChannelCapabilities::for_builtin(kind),
            outbound,
            next_request,
        })
    }

    fn emit_kernel_event(&self, event: &KernelEvent) -> Result<(), ChannelError> {
        self.outbound
            .send(OutboundMessage::Event(ServerMessage::Event(map_kernel_event(
                event,
            ))))
            .map_err(|_| ChannelError::Disconnected)
    }
}

#[async_trait::async_trait]
impl Channel for LocalIpcChannel {
    fn kind(&self) -> ChannelKind {
        self.kind
    }

    fn capabilities(&self) -> ChannelCapabilities {
        self.capabilities.clone()
    }

    async fn receive(&self) -> Result<ChannelInbound, ChannelError> {
        Err(ChannelError::Unsupported(
            "local IPC receive is driven by the daemon connection loop",
        ))
    }

    async fn send(&self, _out: ChannelOutbound) -> Result<(), ChannelError> {
        Err(ChannelError::Unsupported(
            "local IPC send is handled through daemon event framing",
        ))
    }

    async fn confirm(&self, prompt: ConfirmPrompt) -> Result<ConfirmOutcome, ChannelError> {
        let request_id = self.next_request.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        let payload = ConfirmRequestPayload {
            request_id,
            program: prompt.program,
            args: prompt.args,
            cwd: prompt.cwd.map(|path| path.display().to_string()),
            rendered: prompt.rendered,
        };
        self.outbound
            .send(OutboundMessage::Confirm(payload, tx))
            .map_err(|_| ChannelError::Disconnected)?;

        match rx.await.map_err(|_| ChannelError::Disconnected)? {
            ConfirmDecisionPayload::AllowOnce => Ok(ConfirmOutcome::AllowOnce),
            ConfirmDecisionPayload::AllowSession => Ok(ConfirmOutcome::AllowSession),
            ConfirmDecisionPayload::Deny => Ok(ConfirmOutcome::Deny),
        }
    }

    async fn shutdown(self: Arc<Self>) -> Result<(), ChannelError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl ConfirmPrompter for LocalIpcChannel {
    async fn confirm(&self, req: ConfirmRequest) -> ConfirmDecision {
        let prompt = ConfirmPrompt {
            request_id: None,
            program: req.program,
            args: req.args,
            cwd: req.cwd,
            rendered: req.rendered,
            expires_at: None,
        };
        match Channel::confirm(self, prompt).await {
            Ok(ConfirmOutcome::AllowOnce) => ConfirmDecision::AllowOnce,
            Ok(ConfirmOutcome::AllowSession) => ConfirmDecision::AllowSession,
            _ => ConfirmDecision::Deny,
        }
    }
}

#[async_trait::async_trait]
impl InputPrompter for LocalIpcChannel {
    async fn request_input(&self, req: InputRequest) -> InputResponse {
        let request_id = self.next_request.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        let payload = InputRequestPayload {
            request_id,
            prompt: req.prompt,
            allow_empty: req.allow_empty,
        };
        if self
            .outbound
            .send(OutboundMessage::Input(payload, tx))
            .is_err()
        {
            return InputResponse::Cancelled;
        }

        match rx.await {
            Ok(InputResponsePayload::Submitted(value)) => InputResponse::Submitted(value),
            _ => InputResponse::Cancelled,
        }
    }
}

fn model_to_payload(model: &ModelConfig) -> ModelConfigPayload {
    ModelConfigPayload {
        provider: match model.provider {
            allbert_kernel::Provider::Anthropic => ProviderKind::Anthropic,
            allbert_kernel::Provider::Openrouter => ProviderKind::Openrouter,
        },
        model_id: model.model_id.clone(),
        api_key_env: model.api_key_env.clone(),
        max_tokens: model.max_tokens,
    }
}

fn model_from_payload(model: ModelConfigPayload) -> ModelConfig {
    ModelConfig {
        provider: match model.provider {
            ProviderKind::Anthropic => allbert_kernel::Provider::Anthropic,
            ProviderKind::Openrouter => allbert_kernel::Provider::Openrouter,
        },
        model_id: model.model_id,
        api_key_env: model.api_key_env,
        max_tokens: model.max_tokens,
    }
}

fn map_kernel_event(event: &KernelEvent) -> KernelEventPayload {
    match event {
        KernelEvent::SkillTier1Surfaced { skill_name } => KernelEventPayload::SkillTier1Surfaced {
            skill_name: skill_name.clone(),
        },
        KernelEvent::SkillTier2Activated { skill_name } => {
            KernelEventPayload::SkillTier2Activated {
                skill_name: skill_name.clone(),
            }
        }
        KernelEvent::SkillTier3Referenced { skill_name, path } => {
            KernelEventPayload::SkillTier3Referenced {
                skill_name: skill_name.clone(),
                path: path.clone(),
            }
        }
        KernelEvent::AssistantText(text) => KernelEventPayload::AssistantText(text.clone()),
        KernelEvent::ToolCall { name, input } => KernelEventPayload::ToolCall {
            name: name.clone(),
            input: input.clone(),
        },
        KernelEvent::ToolResult { name, ok, content } => KernelEventPayload::ToolResult {
            name: name.clone(),
            ok: *ok,
            content: content.clone(),
        },
        KernelEvent::Cost(entry) => KernelEventPayload::Cost {
            usd_estimate: entry.usd_estimate,
        },
        KernelEvent::TurnDone { hit_turn_limit } => KernelEventPayload::TurnDone {
            hit_turn_limit: *hit_turn_limit,
        },
    }
}

fn map_kernel_error(error: KernelError) -> DaemonError {
    DaemonError::Protocol(error.to_string())
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

fn append_debug_line(state: &SharedState, line: &str) -> Result<(), DaemonError> {
    if !state.trace_enabled.load(Ordering::SeqCst) {
        return Ok(());
    }

    append_log_line(&state.debug_log_path, line)
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
