use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    Arc, Mutex as StdMutex,
};
use std::time::Instant;

use allbert_channels::{
    Channel, ChannelCapabilities, ChannelError, ChannelInbound, ChannelOutbound, ConfirmOutcome,
    ConfirmPrompt,
};
use allbert_kernel::{
    check_in_enabled, ensure_identity_record, load_heartbeat_record, quiet_hours_active,
    resolve_identity_id_for_sender, supports_proactive_delivery, AllbertPaths, Config,
    CrossChannelRouting, HeartbeatNagCadence,
};
use allbert_kernel::{
    job_manager::JobManager as KernelJobManager,
    llm::{ChatAttachment, ChatAttachmentKind, ChatMessage, ChatRole},
    llm::{DefaultProviderFactory, ProviderFactory},
    ActiveSkill, ConfirmDecision, ConfirmPrompter, ConfirmRequest, FrontendAdapter, InputPrompter,
    InputRequest, InputResponse, Intent, Kernel, KernelError, KernelEvent, ModelConfig,
    SessionSnapshot, LEGACY_SENTINEL_IDENTITY, LOCAL_REPL_SENDER,
};
use allbert_proto::{
    AttachedChannel, ChannelKind, ChannelRuntimeStatusPayload, ClientMessage,
    ConfirmDecisionPayload, ConfirmReplyPayload, ConfirmRequestPayload, DaemonLockPayload,
    DaemonStatus, InboxApprovalPayload, InboxQueryPayload, InboxResolveResultPayload,
    InputReplyPayload, InputRequestPayload, InputResponsePayload, KernelEventPayload,
    ModelConfigPayload, ProtocolError, ProviderKind, ServerHello, ServerMessage,
    SessionResumeEntry, SessionStatus, TurnBudgetOverridePayload, TurnResult, PROTOCOL_VERSION,
};
use bytes::Bytes;
use chrono::{Datelike, Utc};
use futures_util::{future::join_all, SinkExt, StreamExt};
use interprocess::local_socket::{
    prelude::*,
    tokio::{prelude::*, Listener as LocalSocketListener, Stream as LocalSocketStream},
    ConnectOptions, GenericFilePath, ListenerOptions,
};
use serde::{Deserialize, Serialize};
use teloxide::{
    net::Download,
    payloads::{GetUpdatesSetters, SendMessageSetters},
    prelude::{Request, Requester},
    types::{ChatId, Message, ParseMode, PhotoSize, Update, UpdateKind, UserId},
    Bot,
};
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
    telegram_status: Arc<TelegramRuntimeStatus>,
    approval_inbox_retention_days: Arc<AtomicUsize>,
    inbox_index: Arc<StdMutex<HashMap<String, InboxApprovalPayload>>>,
    live_approvals: Arc<StdMutex<HashMap<String, LiveApproval>>>,
    telegram_runtime: Arc<StdMutex<Option<Arc<TelegramRuntime>>>>,
    heartbeat_runtime: Arc<StdMutex<HeartbeatRuntimeState>>,
    notifications: broadcast::Sender<ServerMessage>,
    tasks: Arc<TaskTracker>,
}

struct SessionHandle {
    session_id: String,
    channel: StdMutex<ChannelKind>,
    sender_id: StdMutex<Option<String>>,
    identity_id: StdMutex<Option<String>>,
    kernel: Arc<Mutex<Kernel>>,
}

#[derive(Default)]
struct TelegramRuntimeStatus {
    running: AtomicBool,
    queue_depth: AtomicUsize,
    last_error: StdMutex<Option<String>>,
}

impl SessionHandle {
    fn channel(&self) -> ChannelKind {
        *self.channel.lock().unwrap()
    }

    fn set_channel(&self, channel: ChannelKind) {
        *self.channel.lock().unwrap() = channel;
    }

    fn sender_id(&self) -> Option<String> {
        self.sender_id.lock().unwrap().clone()
    }

    fn set_sender_id(&self, sender_id: Option<String>) {
        *self.sender_id.lock().unwrap() = sender_id;
    }

    fn identity_id(&self) -> Option<String> {
        self.identity_id.lock().unwrap().clone()
    }

    fn set_identity_id(&self, identity_id: Option<String>) {
        *self.identity_id.lock().unwrap() = identity_id;
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SessionJournalMeta {
    session_id: String,
    channel: ChannelKind,
    #[serde(default)]
    sender_id: Option<String>,
    #[serde(default)]
    identity_id: Option<String>,
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
    #[serde(default)]
    pending_approvals: Vec<String>,
    #[serde(default, rename = "pending_approval", skip_serializing)]
    legacy_pending_approval: Option<String>,
}

#[derive(Debug, Clone)]
struct SessionJournalSnapshot {
    meta: SessionJournalMeta,
}

impl SessionJournalMeta {
    fn pending_approvals(&self) -> Vec<String> {
        let mut approvals = self.pending_approvals.clone();
        if let Some(legacy) = &self.legacy_pending_approval {
            if !approvals.iter().any(|id| id == legacy) {
                approvals.push(legacy.clone());
            }
        }
        approvals
    }

    fn set_pending_approvals(&mut self, approvals: Vec<String>) {
        self.pending_approvals = approvals;
        self.legacy_pending_approval = None;
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum PendingApprovalStatus {
    Pending,
    Accepted,
    Rejected,
    Timeout,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PendingApprovalFrontmatter {
    id: String,
    session_id: String,
    channel: ChannelKind,
    sender: String,
    agent: String,
    tool: String,
    request_id: u64,
    requested_at: String,
    expires_at: String,
    #[serde(default = "default_pending_approval_kind")]
    kind: PendingApprovalKind,
    status: PendingApprovalStatus,
    #[serde(default)]
    resolved_at: Option<String>,
    #[serde(default)]
    resolver: Option<String>,
    #[serde(default)]
    reply: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum PendingApprovalKind {
    ToolApproval,
    CostCapOverride,
    JobApproval,
}

impl PendingApprovalKind {
    fn as_str(&self) -> &'static str {
        match self {
            Self::ToolApproval => "tool-approval",
            Self::CostCapOverride => "cost-cap-override",
            Self::JobApproval => "job-approval",
        }
    }
}

fn default_pending_approval_kind() -> PendingApprovalKind {
    PendingApprovalKind::ToolApproval
}

#[derive(Debug, Clone)]
struct PendingApprovalRecord {
    frontmatter: PendingApprovalFrontmatter,
    rendered: String,
}

enum LiveApproval {
    Tool {
        reply: oneshot::Sender<ConfirmDecisionPayload>,
    },
    CostCap {
        session_id: String,
        sender_id: String,
        chat_id: i64,
        input: String,
    },
    JobRetry {
        job_name: String,
    },
}

struct ApprovalResolver {
    identity_id: Option<String>,
    resolver_key: String,
}

struct ApprovalLookup {
    payload: InboxApprovalPayload,
}

#[derive(Debug, Clone)]
struct CompletedTurnRecord {
    user_input: String,
    user_attachments: Vec<ChatAttachment>,
    assistant_text: Option<String>,
    tool_results: Vec<ToolJournalEntry>,
    cost_delta_usd: f64,
}

#[derive(Default)]
struct HeartbeatRuntimeState {
    last_inbox_nag_marker: Option<String>,
}

#[derive(Debug, Clone)]
struct ToolJournalEntry {
    name: String,
    ok: bool,
    content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DaemonLockRecord {
    pid: u32,
    host: String,
    started_at: String,
}

#[derive(Clone)]
struct DaemonJobManager {
    state: SharedState,
}

#[allow(clippy::large_enum_variant)]
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
        let _ = release_daemon_lock(&self.state.paths, Some(std::process::id()));
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
    allbert_kernel::ensure_identity_record(&paths)?;
    allbert_kernel::memory::bootstrap_curated_memory(&paths, &config.memory)?;
    archive_expired_sessions(&paths, &config)?;
    reconcile_pending_approvals(&paths)?;
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
    let lock_record = acquire_daemon_lock(&paths)?;

    prepare_socket_dir(&socket_path)?;
    let listener = match bind_listener(&socket_path).await {
        Ok(listener) => listener,
        Err(error) => {
            let _ = release_daemon_lock(&paths, Some(std::process::id()));
            return Err(error);
        }
    };

    let shutdown = CancellationToken::new();
    let (notifications, _) = broadcast::channel(64);
    let approval_inbox_retention_days = config.channels.approval_inbox_retention_days as usize;
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
        telegram_status: Arc::new(TelegramRuntimeStatus::default()),
        approval_inbox_retention_days: Arc::new(AtomicUsize::new(approval_inbox_retention_days)),
        inbox_index: Arc::new(StdMutex::new(HashMap::new())),
        live_approvals: Arc::new(StdMutex::new(HashMap::new())),
        telegram_runtime: Arc::new(StdMutex::new(None)),
        heartbeat_runtime: Arc::new(StdMutex::new(HeartbeatRuntimeState::default())),
        notifications,
        tasks: Arc::new(TaskTracker::new()),
    };
    rebuild_inbox_index(&state)?;
    append_log_line(
        &state.log_path,
        &format!(
            "boot pid={} socket={} trace={} lock_host={}",
            std::process::id(),
            socket_path.display(),
            state.trace_enabled.load(Ordering::SeqCst),
            lock_record.host
        ),
    )?;

    if let Err(error) = spawn_telegram_pilot(state.clone()).await {
        let _ = release_daemon_lock(&state.paths, Some(std::process::id()));
        return Err(error);
    }

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
        set_socket_permissions_best_effort(socket_path)?;
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
                let _ = run_heartbeat_tick(&state, Utc::now()).await;
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
    let client_kind = match hello {
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
            client.client_kind
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
    };

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
                let sender_id = match open.channel {
                    ChannelKind::Repl => Some(LOCAL_REPL_SENDER.to_string()),
                    _ => None,
                };
                let session_id = match open.session_id {
                    Some(session_id) => session_id,
                    None => default_attach_session_id(&state, open.channel).await?,
                };

                let session =
                    get_or_create_session(&state, open.channel, session_id, sender_id).await?;
                let attached = AttachedChannel {
                    channel: session.channel(),
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
                let lock_owner = load_daemon_lock(&state.paths).ok().flatten();
                let model = state.default_config.read().await.model.clone();
                send_server_message(
                    &mut framed,
                    &ServerMessage::Status(DaemonStatus {
                        daemon_id: state.daemon_id.clone(),
                        pid: std::process::id(),
                        socket_path: state.socket_path.display().to_string(),
                        started_at: state.started_at.clone(),
                        session_count: state.sessions.read().await.len(),
                        trace_enabled: state.trace_enabled.load(Ordering::SeqCst),
                        lock_owner: lock_owner.map(|record| DaemonLockPayload {
                            pid: record.pid,
                            host: record.host,
                            started_at: record.started_at,
                        }),
                        model_api_key_env: model.api_key_env.clone(),
                        model_api_key_visible: std::env::var_os(&model.api_key_env).is_some(),
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
            ClientMessage::ListInbox(query) => {
                let approvals = list_inbox_entries(&state, query);
                send_server_message(&mut framed, &ServerMessage::InboxApprovals(approvals)).await?;
            }
            ClientMessage::ShowInboxApproval(approval_id) => {
                match show_inbox_entry(&state, &approval_id)? {
                    Some(approval) => {
                        send_server_message(&mut framed, &ServerMessage::InboxApproval(approval))
                            .await?;
                    }
                    None => {
                        send_server_message(
                            &mut framed,
                            &ServerMessage::Error(ProtocolError {
                                code: "approval_not_found".into(),
                                message: format!("approval not found: {approval_id}"),
                            }),
                        )
                        .await?;
                    }
                }
            }
            ClientMessage::ResolveInboxApproval(resolve) => {
                let resolver =
                    resolver_for_connection(&state.paths, client_kind, attached_session.as_ref())?;
                let result = resolve_inbox_approval_for_actor(
                    &state,
                    &resolver,
                    &resolve.approval_id,
                    resolve.accept,
                    resolve.reason,
                )
                .await?;
                send_server_message(&mut framed, &ServerMessage::InboxResolveResult(result))
                    .await?;
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
                persist_kernel_session(
                    &state.paths,
                    session.channel(),
                    session.sender_id(),
                    session.identity_id(),
                    &kernel,
                )
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
            ClientMessage::SetTurnBudgetOverride(TurnBudgetOverridePayload { usd, seconds }) => {
                let session = require_session(attached_session.as_ref())?;
                let mut kernel = session.kernel.lock().await;
                kernel
                    .set_turn_budget_override(usd, seconds)
                    .map_err(map_kernel_error)?;
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
                state.approval_inbox_retention_days.store(
                    reloaded.channels.approval_inbox_retention_days as usize,
                    Ordering::SeqCst,
                );
                *state.default_config.write().await = reloaded.clone();
                rebuild_inbox_index(&state)?;
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
                persist_kernel_session(
                    &state.paths,
                    session.channel(),
                    session.sender_id(),
                    session.identity_id(),
                    &kernel,
                )
                .map_err(map_kernel_error)?;
                send_server_message(&mut framed, &ServerMessage::Ack).await?;
            }
            ClientMessage::ListChannelRuntimes => {
                send_server_message(
                    &mut framed,
                    &ServerMessage::ChannelRuntimes(channel_runtime_statuses(&state)),
                )
                .await?;
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
    sender_id: Option<String>,
) -> Result<Arc<SessionHandle>, DaemonError> {
    let resolved_identity_id = resolve_identity_id(&state.paths, channel, sender_id.as_deref())?;
    if let Some(existing) = state.sessions.read().await.get(&session_id).cloned() {
        existing.set_channel(channel);
        if sender_id.is_some() {
            existing.set_sender_id(sender_id.clone());
        }
        if resolved_identity_id.is_some() {
            existing.set_identity_id(resolved_identity_id.clone());
        }
        if sender_id.is_some() || resolved_identity_id.is_some() {
            let kernel = existing.kernel.lock().await;
            persist_kernel_session(
                &state.paths,
                channel,
                sender_id,
                resolved_identity_id,
                &kernel,
            )
            .map_err(map_kernel_error)?;
        }
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
    let (restored_sender_id, restored_identity_id) =
        if let Some(snapshot) = load_session_snapshot(&state.paths, &session_id)? {
            let restored_sender_id = snapshot.meta.sender_id.clone();
            let restored_identity_id = snapshot
                .meta
                .identity_id
                .clone()
                .or_else(|| resolved_identity_id.clone())
                .or_else(|| Some(LEGACY_SENTINEL_IDENTITY.to_string()));
            kernel
                .restore_session_snapshot(snapshot_to_kernel(snapshot.meta))
                .await
                .map_err(map_kernel_error)?;
            (restored_sender_id, restored_identity_id)
        } else {
            persist_kernel_session(
                &state.paths,
                channel,
                sender_id.clone(),
                resolved_identity_id.clone(),
                &kernel,
            )
            .map_err(map_kernel_error)?;
            (sender_id.clone(), resolved_identity_id.clone())
        };
    kernel.register_job_manager(Arc::new(DaemonJobManager {
        state: state.clone(),
    }));
    let effective_sender_id = sender_id.or(restored_sender_id);
    let effective_identity_id = resolved_identity_id.or(restored_identity_id);
    let handle = Arc::new(SessionHandle {
        session_id: session_id.clone(),
        channel: StdMutex::new(channel),
        sender_id: StdMutex::new(effective_sender_id),
        identity_id: StdMutex::new(effective_identity_id),
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
    let mut planned = {
        let mut manager = state.job_manager.lock().await;
        manager.plan_due_runs(&state.paths, defaults, now)?
    };
    let heartbeat = load_heartbeat_record(&state.paths).ok();
    planned.retain(|definition| match definition.name.as_str() {
        "daily-brief" | "weekly-review" => heartbeat
            .as_ref()
            .map(|record| check_in_enabled(record, &definition.name))
            .unwrap_or(false),
        _ => true,
    });
    execute_planned_jobs(state, defaults, planned).await
}

async fn run_heartbeat_tick(
    state: &SharedState,
    now: chrono::DateTime<Utc>,
) -> Result<(), DaemonError> {
    let Ok(record) = load_heartbeat_record(&state.paths) else {
        return Ok(());
    };
    if quiet_hours_active(&record, now) {
        return Ok(());
    }
    if !record.inbox_nag.enabled || matches!(record.inbox_nag.cadence, HeartbeatNagCadence::Off) {
        return Ok(());
    }
    let channel = record.inbox_nag.channel.unwrap_or(record.primary_channel);
    if !supports_proactive_delivery(channel) || channel != ChannelKind::Telegram {
        return Ok(());
    }
    let Some(identity_id) = local_operator_identity_id(&state.paths)? else {
        return Ok(());
    };
    let approvals = list_inbox_entries(
        state,
        InboxQueryPayload {
            identity: Some(identity_id),
            kind: None,
            include_resolved: false,
        },
    );
    if approvals.is_empty() {
        return Ok(());
    }
    let Some(marker) = inbox_nag_marker(&record, now) else {
        return Ok(());
    };
    {
        let mut heartbeat = state.heartbeat_runtime.lock().unwrap();
        if heartbeat.last_inbox_nag_marker.as_deref() == Some(marker.as_str()) {
            return Ok(());
        }
        heartbeat.last_inbox_nag_marker = Some(marker);
    }
    let Some(chat_id) = heartbeat_telegram_chat_id(&state.paths)? else {
        return Ok(());
    };
    let runtime = { state.telegram_runtime.lock().unwrap().clone() };
    if let Some(runtime) = runtime {
        let _ = runtime
            .send_text(chat_id, render_inbox_nag_message(&approvals))
            .await?;
    }
    Ok(())
}

fn inbox_nag_marker(
    record: &allbert_kernel::HeartbeatRecord,
    now: chrono::DateTime<Utc>,
) -> Option<String> {
    let timezone = record.timezone.parse::<chrono_tz::Tz>().ok()?;
    let local = now.with_timezone(&timezone);
    let time = record.inbox_nag.time.as_deref()?;
    let mut pieces = time.split(':');
    let hour = pieces.next()?.parse::<u32>().ok()?;
    let minute = pieces.next()?.parse::<u32>().ok()?;
    let target = chrono::NaiveTime::from_hms_opt(hour, minute, 0)?;
    if local.time() < target {
        return None;
    }
    match record.inbox_nag.cadence {
        HeartbeatNagCadence::Daily => Some(format!("daily-{}", local.date_naive())),
        HeartbeatNagCadence::Weekly => {
            if local.weekday() != chrono::Weekday::Mon {
                return None;
            }
            let week = local.iso_week();
            Some(format!("weekly-{}-{}", week.year(), week.week()))
        }
        HeartbeatNagCadence::Off => None,
    }
}

fn heartbeat_telegram_chat_id(paths: &AllbertPaths) -> Result<Option<i64>, DaemonError> {
    let record = ensure_identity_record(paths).map_err(map_kernel_error)?;
    Ok(record
        .channels
        .into_iter()
        .find(|binding| binding.kind == ChannelKind::Telegram)
        .and_then(|binding| parse_telegram_chat_id(&binding.sender)))
}

fn parse_telegram_chat_id(sender: &str) -> Option<i64> {
    let value = sender.strip_prefix("telegram:")?;
    value.split(':').next()?.parse::<i64>().ok()
}

fn render_inbox_nag_message(approvals: &[InboxApprovalPayload]) -> String {
    let mut by_kind = BTreeMap::new();
    for approval in approvals {
        *by_kind.entry(approval.kind.as_str()).or_insert(0usize) += 1;
    }
    let mut segments = vec![format!(
        "{} pending approval{}",
        approvals.len(),
        if approvals.len() == 1 { "" } else { "s" }
    )];
    for (kind, count) in by_kind {
        let label = match kind {
            "cost-cap-override" => "cost-cap override",
            "job-approval" => "job approval",
            _ => "tool approval",
        };
        segments.push(format!(
            "{} {}{}",
            count,
            label,
            if count == 1 { "" } else { "s" }
        ));
    }
    format!(
        "Inbox nag: {}. Review with `allbert-cli inbox list`.",
        segments.join(", ")
    )
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
        let state = state.clone();
        async move {
            let name = definition.name.clone();
            let run_id = uuid::Uuid::new_v4().to_string();
            let session_id = format!("job-{}-{}", definition.name, &run_id[..8]);
            let adapter = FrontendAdapter {
                on_event: Box::new(|_| {}),
                confirm: Arc::new(JobApprovalPrompter {
                    state: state.clone(),
                    session_id: session_id.clone(),
                    job_name: definition.name.clone(),
                }),
                input: Arc::new(JobInputCancelPrompter),
            };
            let record = execute_job(
                &paths,
                &defaults,
                provider_factory,
                job_ephemeral_sessions,
                shutdown,
                &definition,
                run_id,
                session_id,
                adapter,
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

#[async_trait::async_trait]
trait TelegramApi: Send + Sync {
    async fn send_message(&self, chat_id: i64, text: String) -> Result<i32, String>;
    async fn download_photo(&self, photo: &PhotoSize, destination: &Path) -> Result<(), String>;
}

struct TeloxideApi {
    bot: Bot,
}

#[async_trait::async_trait]
impl TelegramApi for TeloxideApi {
    async fn send_message(&self, chat_id: i64, text: String) -> Result<i32, String> {
        self.bot
            .send_message(ChatId(chat_id), text)
            .parse_mode(ParseMode::MarkdownV2)
            .send()
            .await
            .map(|message| message.id.0)
            .map_err(|err| err.to_string())
    }

    async fn download_photo(&self, photo: &PhotoSize, destination: &Path) -> Result<(), String> {
        let file = self
            .bot
            .get_file(photo.file.id.clone())
            .send()
            .await
            .map_err(|err| err.to_string())?;
        let mut output = tokio::fs::File::create(destination)
            .await
            .map_err(|err| err.to_string())?;
        self.bot
            .download_file(&file.path, &mut output)
            .await
            .map_err(|err| err.to_string())
    }
}

struct TelegramSendRequest {
    chat_id: i64,
    text: String,
    reply: oneshot::Sender<Result<Vec<i32>, DaemonError>>,
}

#[derive(Clone)]
struct TelegramOutboundQueue {
    tx: mpsc::UnboundedSender<TelegramSendRequest>,
    status: Arc<TelegramRuntimeStatus>,
}

impl TelegramOutboundQueue {
    fn spawn(
        state: &SharedState,
        api: Arc<dyn TelegramApi>,
        per_chat_interval: Duration,
        global_interval: Duration,
    ) -> Arc<Self> {
        let (tx, rx) = mpsc::unbounded_channel();
        let queue = Arc::new(Self {
            tx,
            status: state.telegram_status.clone(),
        });
        let status = state.telegram_status.clone();
        state.tasks.spawn(async move {
            telegram_outbound_worker(api, status, per_chat_interval, global_interval, rx).await;
        });
        queue
    }

    async fn send_text(&self, chat_id: i64, text: String) -> Result<Vec<i32>, DaemonError> {
        if text.trim().is_empty() {
            return Ok(Vec::new());
        }
        let (reply_tx, reply_rx) = oneshot::channel();
        self.status.queue_depth.fetch_add(1, Ordering::SeqCst);
        self.tx
            .send(TelegramSendRequest {
                chat_id,
                text,
                reply: reply_tx,
            })
            .map_err(|_| DaemonError::Protocol("telegram outbound queue closed".into()))?;
        reply_rx
            .await
            .map_err(|_| DaemonError::Protocol("telegram outbound response dropped".into()))?
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum TelegramCommand {
    Text(String),
    Reset,
    Approve(String),
    Reject(String),
    Override(String),
}

#[derive(Clone)]
struct TelegramRuntime {
    state: SharedState,
    api: Arc<dyn TelegramApi>,
    outbound: Arc<TelegramOutboundQueue>,
    allowed_chats: HashSet<i64>,
    pending_cap_overrides: Arc<StdMutex<HashMap<String, String>>>,
}

impl TelegramRuntime {
    async fn handle_update(self: Arc<Self>, update: Update) {
        let UpdateKind::Message(message) = update.kind else {
            return;
        };
        if let Err(error) = self.handle_message(message).await {
            self.record_error(format!("telegram update handling failed: {error}"));
        }
    }

    async fn handle_message(self: &Arc<Self>, message: Message) -> Result<(), DaemonError> {
        let chat_id = message.chat.id.0;
        if !self.allowed_chats.contains(&chat_id) {
            append_debug_line(
                &self.state,
                &format!("telegram ignored message from unallowlisted chat={chat_id}"),
            )
            .ok();
            return Ok(());
        }
        let sender_id = telegram_sender_key(chat_id, message.from.as_ref().map(|user| user.id));
        let text = message
            .text()
            .or_else(|| message.caption())
            .map(|value| value.to_string());
        let photos = message
            .photo()
            .map(|value| value.to_vec())
            .unwrap_or_default();
        if text.is_none() && photos.is_empty() {
            append_debug_line(
                &self.state,
                &format!("telegram ignored unsupported message chat={chat_id} sender={sender_id}"),
            )
            .ok();
            return Ok(());
        }

        match parse_telegram_command(text.as_deref().unwrap_or_default()) {
            TelegramCommand::Approve(approval_id) => {
                self.resolve_approval(chat_id, &sender_id, &approval_id, true)
                    .await?;
            }
            TelegramCommand::Reject(approval_id) => {
                self.resolve_approval(chat_id, &sender_id, &approval_id, false)
                    .await?;
            }
            TelegramCommand::Reset => {
                let session = self.select_session(&sender_id, true).await?;
                self.send_text(
                    chat_id,
                    format!("Started a new session: {}", session.session_id),
                )
                .await?;
            }
            TelegramCommand::Override(reason) => {
                self.retry_with_override(chat_id, &sender_id, reason)
                    .await?;
            }
            TelegramCommand::Text(input) => {
                let session = self.select_session(&sender_id, false).await?;
                if photos.is_empty() {
                    let runtime = self.clone();
                    self.state.tasks.spawn(async move {
                        if let Err(error) = runtime.clone().run_turn(session, chat_id, input).await
                        {
                            runtime.record_error(format!("telegram turn failed: {error}"));
                        }
                    });
                } else {
                    let runtime = self.clone();
                    let prompt = if input.trim().is_empty() {
                        "Please analyze the attached image.".to_string()
                    } else {
                        input
                    };
                    self.state.tasks.spawn(async move {
                        if let Err(error) = runtime
                            .clone()
                            .run_photo_turn(session, chat_id, prompt, photos)
                            .await
                        {
                            runtime.record_error(format!("telegram photo turn failed: {error}"));
                        }
                    });
                }
            }
        }
        Ok(())
    }

    async fn send_text(&self, chat_id: i64, text: String) -> Result<Vec<i32>, DaemonError> {
        append_debug_line(
            &self.state,
            &format!(
                "telegram enqueue chat={chat_id} bytes={} queue_depth={}",
                text.len(),
                self.state
                    .telegram_status
                    .queue_depth
                    .load(Ordering::SeqCst)
            ),
        )
        .ok();
        self.outbound.send_text(chat_id, text).await
    }

    async fn select_session(
        &self,
        sender_id: &str,
        force_new: bool,
    ) -> Result<Arc<SessionHandle>, DaemonError> {
        let config = self.state.default_config.read().await.clone();
        let identity_id =
            resolve_identity_id(&self.state.paths, ChannelKind::Telegram, Some(sender_id))?;
        let session_id = if force_new {
            None
        } else {
            let max_age_days = config.daemon.session_max_age_days.into();
            let by_identity = if matches!(
                config.sessions.cross_channel_routing,
                CrossChannelRouting::Inherit
            ) {
                identity_id
                    .as_deref()
                    .map(|identity_id| {
                        find_recent_session_for_identity(
                            &self.state.paths,
                            identity_id,
                            max_age_days,
                        )
                    })
                    .transpose()?
                    .flatten()
            } else {
                None
            };
            by_identity.or(find_recent_telegram_session(
                &self.state.paths,
                sender_id,
                max_age_days,
            )?)
        };
        let session_id = session_id.unwrap_or_else(|| {
            format!(
                "telegram-{}",
                self.state.next_session.fetch_add(1, Ordering::SeqCst)
            )
        });
        get_or_create_session(
            &self.state,
            ChannelKind::Telegram,
            session_id,
            Some(sender_id.to_string()),
        )
        .await
    }

    async fn run_turn(
        self: Arc<Self>,
        session: Arc<SessionHandle>,
        chat_id: i64,
        input: String,
    ) -> Result<(), DaemonError> {
        self.run_turn_with_attachments(session, chat_id, input, Vec::new())
            .await
    }

    async fn run_photo_turn(
        self: Arc<Self>,
        session: Arc<SessionHandle>,
        chat_id: i64,
        input: String,
        photos: Vec<PhotoSize>,
    ) -> Result<(), DaemonError> {
        let supports_images = {
            let kernel = session.kernel.lock().await;
            kernel.supports_image_input()
        };
        if !supports_images {
            self.send_text(
                chat_id,
                "The current model does not accept image input on Telegram. Switch to a vision-capable model or send text only.".into(),
            )
            .await?;
            return Ok(());
        }

        let photo = best_telegram_photo(&photos).ok_or_else(|| {
            DaemonError::Protocol("telegram photo message did not include any photo sizes".into())
        })?;
        let ordinal = self.state.next_request.fetch_add(1, Ordering::SeqCst);
        let destination = next_session_image_path(&self.state.paths, &session.session_id, ordinal);
        if let Some(parent) = destination.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        if let Err(err) = self.api.download_photo(photo, &destination).await {
            self.send_text(
                chat_id,
                "I couldn't download that Telegram photo for analysis. Please try sending it again."
                    .into(),
            )
            .await?;
            return Err(DaemonError::Protocol(format!(
                "download Telegram photo to {}: {err}",
                destination.display()
            )));
        }

        self.run_turn_with_attachments(
            session,
            chat_id,
            input,
            vec![ChatAttachment {
                kind: ChatAttachmentKind::Image,
                path: destination,
                mime_type: Some("image/jpeg".into()),
                display_name: Some("telegram photo".into()),
            }],
        )
        .await
    }

    async fn run_turn_with_attachments(
        self: Arc<Self>,
        session: Arc<SessionHandle>,
        chat_id: i64,
        input: String,
        attachments: Vec<ChatAttachment>,
    ) -> Result<(), DaemonError> {
        append_debug_line(
            &self.state,
            &format!(
                "telegram run_turn session={} sender={:?} input_len={} attachments={}",
                session.session_id,
                session.sender_id(),
                input.len(),
                attachments.len()
            ),
        )
        .ok();
        let sender_id = session
            .sender_id()
            .unwrap_or_else(|| "telegram-unknown".into());
        let (pre_turn_messages, pre_turn_cost) = {
            let kernel = session.kernel.lock().await;
            let snapshot = kernel.export_session_snapshot();
            (snapshot.messages.len(), snapshot.cost_total_usd)
        };
        let assistant_text = Arc::new(StdMutex::new(None::<String>));
        let tool_results = Arc::new(StdMutex::new(Vec::<ToolJournalEntry>::new()));
        let runtime = self.clone();
        let assistant_text_for_events = assistant_text.clone();
        let tool_results_for_events = tool_results.clone();
        let max_tool_bytes = self
            .state
            .default_config
            .read()
            .await
            .memory
            .max_journal_tool_output_bytes;
        let adapter = FrontendAdapter {
            on_event: Box::new(move |event: &KernelEvent| match event {
                KernelEvent::AssistantText(text) => {
                    *assistant_text_for_events.lock().unwrap() = Some(text.clone());
                }
                KernelEvent::ToolResult { name, ok, content } => {
                    tool_results_for_events
                        .lock()
                        .unwrap()
                        .push(ToolJournalEntry {
                            name: name.clone(),
                            ok: *ok,
                            content: truncate_tool_output(content, max_tool_bytes),
                        });
                }
                _ => {}
            }),
            confirm: Arc::new(TelegramConfirmPrompter {
                runtime: runtime.clone(),
                session_id: session.session_id.clone(),
                sender_id: sender_id.clone(),
                chat_id,
            }),
            input: Arc::new(TelegramInputPrompter),
        };

        let result = {
            let mut kernel = session.kernel.lock().await;
            kernel.set_adapter(adapter);
            kernel
                .run_turn_with_attachments(&input, attachments.clone())
                .await
        };

        match result {
            Ok(summary) => {
                let assistant_text = assistant_text.lock().unwrap().clone();
                {
                    let kernel = session.kernel.lock().await;
                    persist_completed_turn(
                        &self.state.paths,
                        ChannelKind::Telegram,
                        session.sender_id(),
                        session.identity_id(),
                        &kernel,
                        CompletedTurnRecord {
                            user_input: input,
                            user_attachments: attachments,
                            assistant_text: assistant_text.clone().or_else(|| {
                                extract_turn_assistant_text(&kernel, pre_turn_messages)
                            }),
                            tool_results: tool_results.lock().unwrap().clone(),
                            cost_delta_usd: (kernel.session_cost_usd() - pre_turn_cost).max(0.0),
                        },
                    )
                    .map_err(map_kernel_error)?;
                }
                if let Some(text) = assistant_text {
                    self.send_text(chat_id, text).await?;
                } else if summary.hit_turn_limit {
                    self.send_text(chat_id, "Turn finished after hitting a turn limit.".into())
                        .await?;
                }
                self.pending_cap_overrides
                    .lock()
                    .unwrap()
                    .remove(&sender_id);
                Ok(())
            }
            Err(error) => {
                let mut message = error.to_string();
                if message.contains("/cost --override <reason>") {
                    let approval_id = format!("approval-{}", uuid::Uuid::new_v4().simple());
                    let approval_timeout_s = self
                        .state
                        .default_config
                        .read()
                        .await
                        .channels
                        .approval_timeout_s;
                    let expires_at = (OffsetDateTime::now_utc()
                        + time::Duration::seconds(approval_timeout_s as i64))
                    .format(&Rfc3339)
                    .unwrap_or_else(|_| now_rfc3339_fallback());
                    let record = PendingApprovalRecord {
                        frontmatter: PendingApprovalFrontmatter {
                            id: approval_id.clone(),
                            session_id: session.session_id.clone(),
                            channel: ChannelKind::Telegram,
                            sender: sender_id.clone(),
                            agent: "allbert/root".into(),
                            tool: "daily-cost-cap".into(),
                            request_id: self.state.next_request.fetch_add(1, Ordering::SeqCst),
                            requested_at: now_rfc3339_fallback(),
                            expires_at,
                            kind: PendingApprovalKind::CostCapOverride,
                            status: PendingApprovalStatus::Pending,
                            resolved_at: None,
                            resolver: None,
                            reply: None,
                        },
                        rendered: format!("{message}\n\n## Blocked input\n\n{}\n", input.trim()),
                    };
                    if write_pending_approval(&self.state.paths, &record).is_ok()
                        && append_session_pending_approval(
                            &self.state.paths,
                            &session.session_id,
                            &approval_id,
                        )
                        .is_ok()
                    {
                        let _ = rebuild_inbox_index(&self.state);
                        self.state.live_approvals.lock().unwrap().insert(
                            approval_id.clone(),
                            LiveApproval::CostCap {
                                session_id: session.session_id.clone(),
                                sender_id: sender_id.clone(),
                                chat_id,
                                input: input.clone(),
                            },
                        );
                        self.pending_cap_overrides
                            .lock()
                            .unwrap()
                            .insert(sender_id.clone(), approval_id.clone());
                        spawn_passive_approval_timeout(
                            &self.state,
                            session.session_id.clone(),
                            approval_id.clone(),
                            approval_timeout_s,
                        );
                    }
                    message = message.replace("/cost --override <reason>", "/override <reason>");
                    self.send_text(
                        chat_id,
                        format!(
                            "{message}\n\nReply `/approve {approval_id}` or `/reject {approval_id}` from any linked surface, or `/override <reason>` here to retry immediately."
                        ),
                    )
                    .await?;
                } else {
                    self.send_text(chat_id, message).await?;
                }
                Ok(())
            }
        }
    }

    async fn resolve_approval(
        &self,
        chat_id: i64,
        sender_id: &str,
        approval_id: &str,
        allow: bool,
    ) -> Result<(), DaemonError> {
        if show_inbox_entry(&self.state, approval_id)?.is_none() {
            self.send_text(chat_id, format!("No pending approval `{approval_id}`."))
                .await?;
            return Ok(());
        }
        let resolver = resolver_for_telegram_sender(&self.state.paths, sender_id)?;
        match resolve_inbox_approval_for_actor(&self.state, &resolver, approval_id, allow, None)
            .await
        {
            Ok(result) => {
                let verb = if allow { "Approved" } else { "Rejected" };
                let suffix = result
                    .note
                    .map(|note| format!(" {note}"))
                    .unwrap_or_default();
                self.send_text(chat_id, format!("{verb} `{approval_id}`.{suffix}"))
                    .await?;
            }
            Err(error) => {
                self.send_text(chat_id, error.to_string()).await?;
            }
        }
        Ok(())
    }

    async fn retry_with_override(
        self: &Arc<Self>,
        chat_id: i64,
        sender_id: &str,
        reason: String,
    ) -> Result<(), DaemonError> {
        let approval_id = {
            let mut pending = self.pending_cap_overrides.lock().unwrap();
            pending.remove(sender_id)
        };
        let Some(approval_id) = approval_id else {
            self.send_text(
                chat_id,
                "There is no recent cost-cap refusal to retry for this sender.".into(),
            )
            .await?;
            return Ok(());
        };
        let resolver = resolver_for_telegram_sender(&self.state.paths, sender_id)?;
        let result = resolve_inbox_approval_for_actor(
            &self.state,
            &resolver,
            &approval_id,
            true,
            Some(reason),
        )
        .await?;
        let suffix = result
            .note
            .map(|note| format!(" {note}"))
            .unwrap_or_default();
        self.send_text(chat_id, format!("Approved `{approval_id}`.{suffix}"))
            .await?;
        Ok(())
    }

    fn record_error(&self, message: String) {
        *self.state.telegram_status.last_error.lock().unwrap() = Some(message.clone());
        append_log_line(&self.state.log_path, &format!("telegram error: {message}")).ok();
    }
}

struct TelegramConfirmPrompter {
    runtime: Arc<TelegramRuntime>,
    session_id: String,
    sender_id: String,
    chat_id: i64,
}

#[async_trait::async_trait]
impl ConfirmPrompter for TelegramConfirmPrompter {
    async fn confirm(&self, req: ConfirmRequest) -> ConfirmDecision {
        let approval_id = format!("approval-{}", uuid::Uuid::new_v4().simple());
        let approval_timeout_s = self
            .runtime
            .state
            .default_config
            .read()
            .await
            .channels
            .approval_timeout_s;
        let expires_at = (OffsetDateTime::now_utc()
            + time::Duration::seconds(approval_timeout_s as i64))
        .format(&Rfc3339)
        .unwrap_or_else(|_| now_rfc3339_fallback());
        let record = PendingApprovalRecord {
            frontmatter: PendingApprovalFrontmatter {
                id: approval_id.clone(),
                session_id: self.session_id.clone(),
                channel: ChannelKind::Telegram,
                sender: self.sender_id.clone(),
                agent: "allbert/root".into(),
                tool: req.program.clone(),
                request_id: self
                    .runtime
                    .state
                    .next_request
                    .fetch_add(1, Ordering::SeqCst),
                requested_at: now_rfc3339_fallback(),
                expires_at: expires_at.clone(),
                kind: PendingApprovalKind::ToolApproval,
                status: PendingApprovalStatus::Pending,
                resolved_at: None,
                resolver: None,
                reply: None,
            },
            rendered: req.rendered.clone(),
        };
        if write_pending_approval(&self.runtime.state.paths, &record).is_err()
            || append_session_pending_approval(
                &self.runtime.state.paths,
                &self.session_id,
                &approval_id,
            )
            .is_err()
            || rebuild_inbox_index(&self.runtime.state).is_err()
        {
            return ConfirmDecision::Deny;
        }
        let prompt = format!(
            "Approval needed `{approval_id}`\n\n{}\n\nReply `/approve {approval_id}` or `/reject {approval_id}` before {}.",
            req.rendered.trim(),
            expires_at
        );
        let (reply_tx, reply_rx) = oneshot::channel();
        self.runtime
            .state
            .live_approvals
            .lock()
            .unwrap()
            .insert(approval_id.clone(), LiveApproval::Tool { reply: reply_tx });
        if self.runtime.send_text(self.chat_id, prompt).await.is_err() {
            self.runtime
                .state
                .live_approvals
                .lock()
                .unwrap()
                .remove(&approval_id);
            let _ = resolve_pending_approval(
                &self.runtime.state.paths,
                &self.session_id,
                &approval_id,
                PendingApprovalStatus::Rejected,
                Some("transport".into()),
                Some("telegram send failure".into()),
            );
            return ConfirmDecision::Deny;
        }

        match tokio::time::timeout(Duration::from_secs(approval_timeout_s), reply_rx).await {
            Ok(Ok(ConfirmDecisionPayload::AllowOnce)) => ConfirmDecision::AllowOnce,
            Ok(Ok(ConfirmDecisionPayload::AllowSession)) => ConfirmDecision::AllowSession,
            Ok(Ok(ConfirmDecisionPayload::Deny)) | Ok(Err(_)) => ConfirmDecision::Deny,
            Ok(Ok(ConfirmDecisionPayload::Timeout)) | Err(_) => {
                if self
                    .runtime
                    .state
                    .live_approvals
                    .lock()
                    .unwrap()
                    .remove(&approval_id)
                    .is_some()
                {
                    let _ = resolve_pending_approval(
                        &self.runtime.state.paths,
                        &self.session_id,
                        &approval_id,
                        PendingApprovalStatus::Timeout,
                        Some("timeout".into()),
                        Some("confirm-timeout".into()),
                    );
                    let _ = rebuild_inbox_index(&self.runtime.state);
                }
                ConfirmDecision::Timeout
            }
        }
    }
}

struct TelegramInputPrompter;

#[async_trait::async_trait]
impl InputPrompter for TelegramInputPrompter {
    async fn request_input(&self, _req: InputRequest) -> InputResponse {
        InputResponse::Cancelled
    }
}

struct JobApprovalPrompter {
    state: SharedState,
    session_id: String,
    job_name: String,
}

#[async_trait::async_trait]
impl ConfirmPrompter for JobApprovalPrompter {
    async fn confirm(&self, req: ConfirmRequest) -> ConfirmDecision {
        let approval_id = format!("approval-{}", uuid::Uuid::new_v4().simple());
        let approval_timeout_s = self
            .state
            .default_config
            .read()
            .await
            .channels
            .approval_timeout_s;
        let expires_at = (OffsetDateTime::now_utc()
            + time::Duration::seconds(approval_timeout_s as i64))
        .format(&Rfc3339)
        .unwrap_or_else(|_| now_rfc3339_fallback());
        let record = PendingApprovalRecord {
            frontmatter: PendingApprovalFrontmatter {
                id: approval_id.clone(),
                session_id: self.session_id.clone(),
                channel: ChannelKind::Jobs,
                sender: self.job_name.clone(),
                agent: "allbert/root".into(),
                tool: req.program,
                request_id: self.state.next_request.fetch_add(1, Ordering::SeqCst),
                requested_at: now_rfc3339_fallback(),
                expires_at,
                kind: PendingApprovalKind::JobApproval,
                status: PendingApprovalStatus::Pending,
                resolved_at: None,
                resolver: None,
                reply: None,
            },
            rendered: req.rendered,
        };
        if write_pending_approval(&self.state.paths, &record).is_err()
            || append_session_pending_approval(&self.state.paths, &self.session_id, &approval_id)
                .is_err()
            || rebuild_inbox_index(&self.state).is_err()
        {
            return ConfirmDecision::Deny;
        }
        self.state.live_approvals.lock().unwrap().insert(
            approval_id.clone(),
            LiveApproval::JobRetry {
                job_name: self.job_name.clone(),
            },
        );
        spawn_passive_approval_timeout(
            &self.state,
            self.session_id.clone(),
            approval_id,
            approval_timeout_s,
        );
        ConfirmDecision::Deny
    }
}

struct JobInputCancelPrompter;

#[async_trait::async_trait]
impl InputPrompter for JobInputCancelPrompter {
    async fn request_input(&self, _req: InputRequest) -> InputResponse {
        InputResponse::Cancelled
    }
}

async fn spawn_telegram_pilot(state: SharedState) -> Result<(), DaemonError> {
    let config = state.default_config.read().await.clone();
    if !config.channels.telegram.enabled {
        state.telegram_status.running.store(false, Ordering::SeqCst);
        *state.telegram_status.last_error.lock().unwrap() = None;
        return Ok(());
    }

    let token = fs::read_to_string(&state.paths.telegram_bot_token)
        .unwrap_or_default()
        .trim()
        .to_string();
    if token.is_empty() {
        state.telegram_status.running.store(false, Ordering::SeqCst);
        *state.telegram_status.last_error.lock().unwrap() = Some(format!(
            "missing Telegram bot token at {}",
            state.paths.telegram_bot_token.display()
        ));
        append_log_line(&state.log_path, "telegram not started: missing bot token").ok();
        return Ok(());
    }

    let allowed_chats = load_telegram_allowed_chats(&state.paths.telegram_allowed_chats)?;
    if allowed_chats.is_empty() {
        state.telegram_status.running.store(false, Ordering::SeqCst);
        *state.telegram_status.last_error.lock().unwrap() = Some(format!(
            "no allowlisted Telegram chats in {}",
            state.paths.telegram_allowed_chats.display()
        ));
        append_log_line(
            &state.log_path,
            "telegram not started: no allowlisted chats",
        )
        .ok();
        return Ok(());
    }

    let bot = Bot::new(token.clone());
    let api: Arc<dyn TelegramApi> = Arc::new(TeloxideApi { bot: bot.clone() });
    let outbound = TelegramOutboundQueue::spawn(
        &state,
        api.clone(),
        Duration::from_millis(config.channels.telegram.min_interval_ms_per_chat),
        Duration::from_millis(config.channels.telegram.min_interval_ms_global),
    );
    let runtime = Arc::new(TelegramRuntime {
        state: state.clone(),
        api,
        outbound,
        allowed_chats,
        pending_cap_overrides: Arc::new(StdMutex::new(HashMap::new())),
    });
    *state.telegram_runtime.lock().unwrap() = Some(runtime.clone());
    state.telegram_status.running.store(true, Ordering::SeqCst);
    *state.telegram_status.last_error.lock().unwrap() = None;
    append_log_line(&state.log_path, "telegram pilot started with long polling").ok();
    state.tasks.spawn(async move {
        telegram_poll_loop(runtime, bot).await;
    });
    Ok(())
}

async fn telegram_poll_loop(runtime: Arc<TelegramRuntime>, bot: Bot) {
    let mut offset: u32 = 0;
    loop {
        if runtime.state.shutdown.is_cancelled() {
            runtime
                .state
                .telegram_status
                .running
                .store(false, Ordering::SeqCst);
            return;
        }

        let mut request = bot.get_updates().timeout(2).limit(50);
        if offset > 0 {
            request = request.offset(offset.try_into().unwrap_or(i32::MAX));
        }
        match request.send().await {
            Ok(updates) => {
                for update in updates {
                    offset = update.id.0 + 1;
                    runtime.clone().handle_update(update).await;
                }
            }
            Err(error) => {
                runtime.record_error(format!("telegram polling error: {error}"));
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
}

async fn telegram_outbound_worker(
    api: Arc<dyn TelegramApi>,
    status: Arc<TelegramRuntimeStatus>,
    per_chat_interval: Duration,
    global_interval: Duration,
    mut rx: mpsc::UnboundedReceiver<TelegramSendRequest>,
) {
    let mut last_global_sent: Option<Instant> = None;
    let mut last_chat_sent: HashMap<i64, Instant> = HashMap::new();
    while let Some(request) = rx.recv().await {
        let result: Result<Vec<i32>, DaemonError> = async {
            let rendered = escape_telegram_markdown_v2(&request.text);
            let chunks = chunk_telegram_markdown_v2(
                &rendered,
                ChannelCapabilities::for_builtin(ChannelKind::Telegram).max_message_size,
            );
            let mut ids = Vec::new();
            for chunk in chunks {
                let now = Instant::now();
                let global_wait = last_global_sent
                    .map(|last| global_interval.saturating_sub(now.duration_since(last)))
                    .unwrap_or_default();
                let per_chat_wait = last_chat_sent
                    .get(&request.chat_id)
                    .map(|last| per_chat_interval.saturating_sub(now.duration_since(*last)))
                    .unwrap_or_default();
                let wait_for = global_wait.max(per_chat_wait);
                if !wait_for.is_zero() {
                    tokio::time::sleep(wait_for).await;
                }
                let message_id = api
                    .send_message(request.chat_id, chunk)
                    .await
                    .map_err(DaemonError::Protocol)?;
                let sent_at = Instant::now();
                last_global_sent = Some(sent_at);
                last_chat_sent.insert(request.chat_id, sent_at);
                ids.push(message_id);
            }
            Ok(ids)
        }
        .await;
        if let Err(error) = &result {
            *status.last_error.lock().unwrap() = Some(error.to_string());
        } else {
            *status.last_error.lock().unwrap() = None;
        }
        status.queue_depth.fetch_sub(1, Ordering::SeqCst);
        let _ = request.reply.send(result);
    }
}

fn load_telegram_allowed_chats(path: &Path) -> Result<HashSet<i64>, DaemonError> {
    if !path.exists() {
        return Ok(HashSet::new());
    }
    let raw = fs::read_to_string(path)?;
    parse_telegram_allowed_chats(&raw)
}

fn parse_telegram_allowed_chats(raw: &str) -> Result<HashSet<i64>, DaemonError> {
    let mut allowed = HashSet::new();
    for (idx, line) in raw.lines().enumerate() {
        let stripped = line.split('#').next().unwrap_or_default().trim();
        if stripped.is_empty() {
            continue;
        }
        let chat_id = stripped.parse::<i64>().map_err(|err| {
            DaemonError::Protocol(format!(
                "parse Telegram allowlisted chat on line {}: {err}",
                idx + 1
            ))
        })?;
        allowed.insert(chat_id);
    }
    Ok(allowed)
}

fn parse_telegram_command(text: &str) -> TelegramCommand {
    let trimmed = text.trim();
    if trimmed == "/reset" {
        return TelegramCommand::Reset;
    }
    if let Some(value) = trimmed.strip_prefix("/approve ") {
        let value = value.trim();
        if !value.is_empty() {
            return TelegramCommand::Approve(value.to_string());
        }
    }
    if let Some(value) = trimmed.strip_prefix("/reject ") {
        let value = value.trim();
        if !value.is_empty() {
            return TelegramCommand::Reject(value.to_string());
        }
    }
    if let Some(value) = trimmed.strip_prefix("/override ") {
        let value = value.trim();
        if !value.is_empty() {
            return TelegramCommand::Override(value.to_string());
        }
    }
    TelegramCommand::Text(text.to_string())
}

fn telegram_sender_key(chat_id: i64, user_id: Option<UserId>) -> String {
    match user_id {
        Some(user_id) => format!("telegram:{chat_id}:{}", user_id.0),
        None => format!("telegram:{chat_id}"),
    }
}

fn channel_label(channel: ChannelKind) -> &'static str {
    match channel {
        ChannelKind::Cli => "cli",
        ChannelKind::Repl => "repl",
        ChannelKind::Jobs => "jobs",
        ChannelKind::Telegram => "telegram",
    }
}

fn best_telegram_photo(photo_sizes: &[PhotoSize]) -> Option<&PhotoSize> {
    photo_sizes.iter().max_by_key(|photo| {
        u64::from(photo.width) * u64::from(photo.height) * 1_000_000 + u64::from(photo.file.size)
    })
}

fn next_session_image_path(paths: &AllbertPaths, session_id: &str, ordinal: u64) -> PathBuf {
    session_artifacts_dir(paths, session_id).join(format!("telegram-photo-{ordinal}.jpg"))
}

fn escape_telegram_markdown_v2(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '_' | '*' | '[' | ']' | '(' | ')' | '~' | '`' | '>' | '#' | '+' | '-' | '=' | '|'
            | '{' | '}' | '.' | '!' => {
                escaped.push('\\');
                escaped.push(ch);
            }
            _ => escaped.push(ch),
        }
    }
    escaped
}

fn chunk_telegram_markdown_v2(text: &str, max_message_size: usize) -> Vec<String> {
    if text.is_empty() {
        return Vec::new();
    }
    if text.len() <= max_message_size {
        return vec![text.to_string()];
    }

    let body_limit = max_message_size.saturating_sub(12).max(1);
    let mut raw_chunks = Vec::new();
    let mut start = 0usize;
    while start < text.len() {
        let mut end = start;
        for (idx, ch) in text[start..].char_indices() {
            let next = start + idx + ch.len_utf8();
            if next - start > body_limit {
                break;
            }
            end = next;
        }
        if end == start {
            end = (start + body_limit).min(text.len());
            while !text.is_char_boundary(end) {
                end -= 1;
            }
        }
        raw_chunks.push(text[start..end].to_string());
        start = end;
    }

    let total = raw_chunks.len();
    raw_chunks
        .into_iter()
        .enumerate()
        .map(|(idx, chunk)| format!("{}/{}\n{}", idx + 1, total, chunk))
        .collect()
}

fn find_recent_telegram_session(
    paths: &AllbertPaths,
    sender_id: &str,
    max_age_days: u32,
) -> Result<Option<String>, DaemonError> {
    let cutoff = OffsetDateTime::now_utc() - time::Duration::days(i64::from(max_age_days));
    let mut latest: Option<(OffsetDateTime, String)> = None;
    for entry in fs::read_dir(&paths.sessions)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let Some(snapshot) = load_session_snapshot(paths, &name)? else {
            continue;
        };
        if snapshot.meta.channel != ChannelKind::Telegram {
            continue;
        }
        if snapshot.meta.sender_id.as_deref() != Some(sender_id) {
            continue;
        }
        let last_activity = OffsetDateTime::parse(&snapshot.meta.last_activity_at, &Rfc3339)
            .unwrap_or_else(|_| OffsetDateTime::now_utc());
        if last_activity < cutoff {
            continue;
        }
        let should_replace = latest
            .as_ref()
            .map(|(best_time, _)| last_activity > *best_time)
            .unwrap_or(true);
        if should_replace {
            latest = Some((last_activity, name));
        }
    }
    Ok(latest.map(|(_, session_id)| session_id))
}

fn resolve_identity_id(
    paths: &AllbertPaths,
    channel: ChannelKind,
    sender_id: Option<&str>,
) -> Result<Option<String>, DaemonError> {
    let Some(sender_id) = sender_id else {
        return Ok(None);
    };
    resolve_identity_id_for_sender(paths, channel, sender_id).map_err(map_kernel_error)
}

fn find_recent_session_for_identity(
    paths: &AllbertPaths,
    identity_id: &str,
    max_age_days: u32,
) -> Result<Option<String>, DaemonError> {
    let cutoff = OffsetDateTime::now_utc() - time::Duration::days(i64::from(max_age_days));
    let mut latest: Option<(OffsetDateTime, String)> = None;
    for entry in fs::read_dir(&paths.sessions)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let Some(snapshot) = load_session_snapshot(paths, &name)? else {
            continue;
        };
        if snapshot.meta.identity_id.as_deref() != Some(identity_id) {
            continue;
        }
        let last_activity = OffsetDateTime::parse(&snapshot.meta.last_activity_at, &Rfc3339)
            .unwrap_or_else(|_| OffsetDateTime::now_utc());
        if last_activity < cutoff {
            continue;
        }
        let should_replace = latest
            .as_ref()
            .map(|(best_time, _)| last_activity > *best_time)
            .unwrap_or(true);
        if should_replace {
            latest = Some((last_activity, name));
        }
    }
    Ok(latest.map(|(_, session_id)| session_id))
}

async fn default_attach_session_id(
    state: &SharedState,
    channel: ChannelKind,
) -> Result<String, DaemonError> {
    let config = state.default_config.read().await.clone();
    match channel {
        ChannelKind::Repl => {
            if matches!(
                config.sessions.cross_channel_routing,
                CrossChannelRouting::Inherit
            ) {
                if let Some(identity_id) =
                    resolve_identity_id(&state.paths, ChannelKind::Repl, Some(LOCAL_REPL_SENDER))?
                {
                    if let Some(session_id) = find_recent_session_for_identity(
                        &state.paths,
                        &identity_id,
                        config.daemon.session_max_age_days.into(),
                    )? {
                        return Ok(session_id);
                    }
                }
            }
            Ok(ChannelKind::Repl.default_session_id())
        }
        ChannelKind::Cli => Ok(format!(
            "cli-{}",
            state.next_session.fetch_add(1, Ordering::SeqCst)
        )),
        ChannelKind::Jobs => Ok(format!(
            "jobs-{}",
            state.next_session.fetch_add(1, Ordering::SeqCst)
        )),
        ChannelKind::Telegram => Ok(format!(
            "telegram-{}",
            state.next_session.fetch_add(1, Ordering::SeqCst)
        )),
    }
}

async fn run_turn_over_channel(
    framed: &mut FramedStream,
    state: &SharedState,
    notifications: &mut broadcast::Receiver<ServerMessage>,
    session: Arc<SessionHandle>,
    input: String,
) -> Result<(), DaemonError> {
    let session_channel = session.channel();
    let session_sender_id = session.sender_id();
    let session_identity_id = session.identity_id();
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
    let local_channel = LocalIpcChannel::new(session_channel, tx, state.next_request.clone());
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
                        let is_async_confirm = session_channel == ChannelKind::Telegram;
                        if is_async_confirm {
                            let approval_id =
                                format!("approval-{}", uuid::Uuid::new_v4().simple());
                            let approval_timeout_s =
                                state.default_config.read().await.channels.approval_timeout_s;
                            let expires_at = (OffsetDateTime::now_utc()
                                + time::Duration::seconds(approval_timeout_s as i64))
                            .format(&Rfc3339)
                            .unwrap_or_else(|_| now_rfc3339_fallback());
                            let record = PendingApprovalRecord {
                                frontmatter: PendingApprovalFrontmatter {
                                    id: approval_id.clone(),
                                    session_id: session.session_id.clone(),
                                    channel: session_channel,
                                    sender: session_sender_id
                                        .clone()
                                        .unwrap_or_else(|| "attached-client".into()),
                                    agent: "allbert/root".into(),
                                    tool: request.program.clone(),
                                    request_id: request.request_id,
                                    requested_at: now_rfc3339_fallback(),
                                    expires_at: expires_at.clone(),
                                    kind: PendingApprovalKind::ToolApproval,
                                    status: PendingApprovalStatus::Pending,
                                    resolved_at: None,
                                    resolver: None,
                                    reply: None,
                                },
                                rendered: request.rendered.clone(),
                            };
                            if write_pending_approval(&state.paths, &record).is_err()
                                || append_session_pending_approval(
                                    &state.paths,
                                    &session.session_id,
                                    &approval_id,
                                )
                                .is_err()
                                || rebuild_inbox_index(state).is_err()
                            {
                                let _ = reply.send(ConfirmDecisionPayload::Deny);
                                continue;
                            }
                            let mut request = request.clone();
                            request.approval_id = Some(approval_id.clone());
                            request.expires_at = Some(expires_at);
                            if send_server_message(
                                framed,
                                &ServerMessage::ConfirmRequest(request.clone()),
                            )
                            .await
                            .is_err()
                            {
                                client_connected = false;
                                let _ = resolve_pending_approval(
                                    &state.paths,
                                    &session.session_id,
                                    &approval_id,
                                    PendingApprovalStatus::Rejected,
                                    Some("transport".into()),
                                    Some("client disconnected before reply".into()),
                                );
                                let _ = reply.send(ConfirmDecisionPayload::Deny);
                                continue;
                            }
                            let (live_tx, live_rx) = oneshot::channel();
                            state.live_approvals.lock().unwrap().insert(
                                approval_id.clone(),
                                LiveApproval::Tool { reply: live_tx },
                            );
                            let timeout = tokio::time::sleep(Duration::from_secs(approval_timeout_s));
                            tokio::pin!(timeout);
                            tokio::pin!(live_rx);
                            let decision = tokio::select! {
                                result = &mut live_rx => {
                                    match result {
                                        Ok(decision) => decision,
                                        Err(_) => ConfirmDecisionPayload::Deny,
                                    }
                                }
                                _ = &mut timeout => {
                                    if state.live_approvals.lock().unwrap().remove(&approval_id).is_some() {
                                        let _ = resolve_pending_approval(
                                            &state.paths,
                                            &session.session_id,
                                            &approval_id,
                                            PendingApprovalStatus::Timeout,
                                            Some("timeout".into()),
                                            Some("confirm-timeout".into()),
                                        );
                                        let _ = rebuild_inbox_index(state);
                                    }
                                    ConfirmDecisionPayload::Timeout
                                }
                                inbound = recv_client_message(framed) => {
                                    match inbound {
                                        Ok(ClientMessage::ConfirmReply(ConfirmReplyPayload {
                                            request_id,
                                            decision,
                                        })) if request_id == request.request_id => {
                                            state.live_approvals.lock().unwrap().remove(&approval_id);
                                            let _ = resolve_pending_approval(
                                                &state.paths,
                                                &session.session_id,
                                                &approval_id,
                                                match decision {
                                                    ConfirmDecisionPayload::AllowOnce
                                                    | ConfirmDecisionPayload::AllowSession => {
                                                        PendingApprovalStatus::Accepted
                                                    }
                                                    ConfirmDecisionPayload::Deny => {
                                                        PendingApprovalStatus::Rejected
                                                    }
                                                    ConfirmDecisionPayload::Timeout => {
                                                        PendingApprovalStatus::Timeout
                                                    }
                                                },
                                                Some(resolver_key(
                                                    session_channel,
                                                    session_sender_id.as_deref(),
                                                )),
                                                Some(format!("{decision:?}")),
                                            );
                                            let _ = rebuild_inbox_index(state);
                                            decision
                                        }
                                        Ok(_) | Err(_) => {
                                            client_connected = false;
                                            if state.live_approvals.lock().unwrap().remove(&approval_id).is_some() {
                                                let _ = resolve_pending_approval(
                                                    &state.paths,
                                                    &session.session_id,
                                                    &approval_id,
                                                    PendingApprovalStatus::Rejected,
                                                    Some("transport".into()),
                                                    Some("unexpected reply".into()),
                                                );
                                                let _ = rebuild_inbox_index(state);
                                            }
                                            ConfirmDecisionPayload::Deny
                                        }
                                    }
                                }
                            };
                            let _ = reply.send(decision);
                        } else {
                            if send_server_message(
                                framed,
                                &ServerMessage::ConfirmRequest(request.clone()),
                            )
                            .await
                            .is_err()
                            {
                                client_connected = false;
                                let _ = reply.send(ConfirmDecisionPayload::Deny);
                                continue;
                            }
                            match recv_client_message(framed).await {
                                Ok(ClientMessage::ConfirmReply(ConfirmReplyPayload {
                                    request_id,
                                    decision,
                                })) if request_id == request.request_id => {
                                    let _ = reply.send(decision);
                                }
                                Ok(_) | Err(_) => {
                                    client_connected = false;
                                    let _ = reply.send(ConfirmDecisionPayload::Deny);
                                }
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
                                session_channel,
                                session_sender_id.clone(),
                                session_identity_id.clone(),
                                &kernel,
                                CompletedTurnRecord {
                                    user_input: input.clone(),
                                    user_attachments: Vec::new(),
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
                        let mut message = error.to_string();
                        if session_channel == ChannelKind::Telegram
                            && message.contains("/cost --override <reason>")
                        {
                            let approval_id = format!("approval-{}", uuid::Uuid::new_v4().simple());
                            let approval_timeout_s =
                                state.default_config.read().await.channels.approval_timeout_s;
                            let expires_at = (OffsetDateTime::now_utc()
                                + time::Duration::seconds(approval_timeout_s as i64))
                            .format(&Rfc3339)
                            .unwrap_or_else(|_| now_rfc3339_fallback());
                            let sender = session_sender_id
                                .clone()
                                .unwrap_or_else(|| LOCAL_REPL_SENDER.to_string());
                            let record = PendingApprovalRecord {
                                frontmatter: PendingApprovalFrontmatter {
                                    id: approval_id.clone(),
                                    session_id: session.session_id.clone(),
                                    channel: ChannelKind::Telegram,
                                    sender: sender.clone(),
                                    agent: "allbert/root".into(),
                                    tool: "daily-cost-cap".into(),
                                    request_id: state.next_request.fetch_add(1, Ordering::SeqCst),
                                    requested_at: now_rfc3339_fallback(),
                                    expires_at,
                                    kind: PendingApprovalKind::CostCapOverride,
                                    status: PendingApprovalStatus::Pending,
                                    resolved_at: None,
                                    resolver: None,
                                    reply: None,
                                },
                                rendered: format!(
                                    "{}\n\n## Blocked input\n\n{}\n",
                                    message,
                                    input.trim()
                                ),
                            };
                            if write_pending_approval(&state.paths, &record).is_ok()
                                && append_session_pending_approval(
                                    &state.paths,
                                    &session.session_id,
                                    &approval_id,
                                )
                                .is_ok()
                            {
                                let _ = rebuild_inbox_index(state);
                                spawn_passive_approval_timeout(
                                    state,
                                    session.session_id.clone(),
                                    approval_id.clone(),
                                    approval_timeout_s,
                                );
                                message = message.replace(
                                    "/cost --override <reason>",
                                    &format!(
                                        "allbert-cli inbox accept {approval_id} --reason <reason>"
                                    ),
                                );
                            }
                        }
                        if client_connected {
                            let _ = send_server_message(
                                framed,
                                &ServerMessage::Error(ProtocolError {
                                    code: "turn_failed".into(),
                                    message,
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

fn channel_runtime_statuses(state: &SharedState) -> Vec<ChannelRuntimeStatusPayload> {
    let telegram_last_error = state.telegram_status.last_error.lock().unwrap().clone();
    vec![
        ChannelRuntimeStatusPayload {
            kind: ChannelKind::Cli,
            running: true,
            queue_depth: None,
            last_error: None,
        },
        ChannelRuntimeStatusPayload {
            kind: ChannelKind::Repl,
            running: true,
            queue_depth: None,
            last_error: None,
        },
        ChannelRuntimeStatusPayload {
            kind: ChannelKind::Jobs,
            running: true,
            queue_depth: None,
            last_error: None,
        },
        ChannelRuntimeStatusPayload {
            kind: ChannelKind::Telegram,
            running: state.telegram_status.running.load(Ordering::SeqCst),
            queue_depth: Some(state.telegram_status.queue_depth.load(Ordering::SeqCst)),
            last_error: telegram_last_error,
        },
    ]
}

fn session_dir(paths: &AllbertPaths, session_id: &str) -> PathBuf {
    paths.sessions.join(session_id)
}

fn session_approvals_dir(paths: &AllbertPaths, session_id: &str) -> PathBuf {
    session_dir(paths, session_id).join("approvals")
}

fn session_approval_path(paths: &AllbertPaths, session_id: &str, approval_id: &str) -> PathBuf {
    session_approvals_dir(paths, session_id).join(format!("{approval_id}.md"))
}

fn session_meta_path(paths: &AllbertPaths, session_id: &str) -> PathBuf {
    session_dir(paths, session_id).join("meta.json")
}

fn session_turns_path(paths: &AllbertPaths, session_id: &str) -> PathBuf {
    session_dir(paths, session_id).join("turns.md")
}

fn session_artifacts_dir(paths: &AllbertPaths, session_id: &str) -> PathBuf {
    session_dir(paths, session_id).join("artifacts")
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

#[allow(clippy::too_many_arguments)]
fn build_session_meta(
    channel: ChannelKind,
    sender_id: Option<String>,
    identity_id: Option<String>,
    kernel: &Kernel,
    started_at: String,
    last_activity_at: String,
    prior_intents: &[String],
    pending_approvals: Vec<String>,
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
        sender_id,
        identity_id,
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
        pending_approvals,
        legacy_pending_approval: None,
    }
}

fn persist_kernel_session(
    paths: &AllbertPaths,
    channel: ChannelKind,
    sender_id: Option<String>,
    identity_id: Option<String>,
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
    let pending_approvals = existing
        .as_ref()
        .map(|snapshot| snapshot.meta.pending_approvals())
        .unwrap_or_default();
    persist_session_meta(
        paths,
        &build_session_meta(
            channel,
            sender_id,
            identity_id,
            kernel,
            started_at,
            now_rfc3339_fallback(),
            &prior_intents,
            pending_approvals,
        ),
    )
}

fn persist_completed_turn(
    paths: &AllbertPaths,
    channel: ChannelKind,
    sender_id: Option<String>,
    identity_id: Option<String>,
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
    let pending_approvals = existing
        .as_ref()
        .map(|snapshot| snapshot.meta.pending_approvals())
        .unwrap_or_default();
    let meta = build_session_meta(
        channel,
        sender_id,
        identity_id,
        kernel,
        started_at,
        now_rfc3339_fallback(),
        &prior_intents,
        pending_approvals,
    );
    persist_session_meta(paths, &meta)?;
    append_turn_record(paths, &meta.session_id, channel, &record).map_err(|err| {
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
    atomic_write(&session_meta_path(paths, &meta.session_id), &rendered).map_err(|e| {
        KernelError::InitFailed(format!(
            "write {}: {e}",
            session_meta_path(paths, &meta.session_id).display()
        ))
    })?;
    let turns = session_turns_path(paths, &meta.session_id);
    if !turns.exists() {
        atomic_write(
            &turns,
            format!(
                "# Session {}\n\n- channel: {:?}\n- started_at: {}\n\n",
                meta.session_id, meta.channel, meta.started_at
            )
            .as_bytes(),
        )
        .map_err(|e| KernelError::InitFailed(format!("write {}: {e}", turns.display())))?;
    }
    Ok(())
}

fn render_pending_approval_markdown(record: &PendingApprovalRecord) -> Result<String, DaemonError> {
    let frontmatter = serde_yaml::to_string(&record.frontmatter)
        .map_err(|err| DaemonError::Protocol(format!("serialize approval frontmatter: {err}")))?;
    Ok(format!(
        "---\n{}---\n\n## Tool invocation\n\n{}\n",
        frontmatter,
        record.rendered.trim()
    ))
}

fn write_pending_approval(
    paths: &AllbertPaths,
    record: &PendingApprovalRecord,
) -> Result<(), DaemonError> {
    let dir = session_approvals_dir(paths, &record.frontmatter.session_id);
    fs::create_dir_all(&dir)?;
    let path = session_approval_path(
        paths,
        &record.frontmatter.session_id,
        &record.frontmatter.id,
    );
    atomic_write(&path, render_pending_approval_markdown(record)?.as_bytes())?;
    Ok(())
}

fn load_pending_approval(
    paths: &AllbertPaths,
    session_id: &str,
    approval_id: &str,
) -> Result<Option<PendingApprovalRecord>, DaemonError> {
    let path = session_approval_path(paths, session_id, approval_id);
    if !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(&path)?;
    let matter = gray_matter::Matter::<gray_matter::engine::YAML>::new();
    let parsed = matter
        .parse::<PendingApprovalFrontmatter>(&raw)
        .map_err(|err| {
            DaemonError::Protocol(format!("parse approval {}: {err}", path.display()))
        })?;
    let Some(frontmatter) = parsed.data else {
        return Err(DaemonError::Protocol(format!(
            "approval file missing frontmatter: {}",
            path.display()
        )));
    };
    Ok(Some(PendingApprovalRecord {
        frontmatter,
        rendered: parsed.content.trim().to_string(),
    }))
}

fn pending_approval_status_label(status: &PendingApprovalStatus) -> &'static str {
    match status {
        PendingApprovalStatus::Pending => "pending",
        PendingApprovalStatus::Accepted => "accepted",
        PendingApprovalStatus::Rejected => "rejected",
        PendingApprovalStatus::Timeout => "timeout",
    }
}

fn session_identity_id(
    paths: &AllbertPaths,
    session_id: &str,
) -> Result<Option<String>, DaemonError> {
    Ok(load_session_snapshot(paths, session_id)?.and_then(|snapshot| snapshot.meta.identity_id))
}

fn pending_approval_to_inbox_payload(
    paths: &AllbertPaths,
    session_id: &str,
    record: &PendingApprovalRecord,
) -> Result<InboxApprovalPayload, DaemonError> {
    Ok(InboxApprovalPayload {
        id: record.frontmatter.id.clone(),
        session_id: session_id.to_string(),
        identity_id: session_identity_id(paths, session_id)?,
        channel: record.frontmatter.channel,
        sender: record.frontmatter.sender.clone(),
        agent: record.frontmatter.agent.clone(),
        tool: record.frontmatter.tool.clone(),
        request_id: record.frontmatter.request_id,
        kind: record.frontmatter.kind.as_str().to_string(),
        requested_at: record.frontmatter.requested_at.clone(),
        expires_at: record.frontmatter.expires_at.clone(),
        status: pending_approval_status_label(&record.frontmatter.status).to_string(),
        resolved_at: record.frontmatter.resolved_at.clone(),
        resolver: record.frontmatter.resolver.clone(),
        reply: record.frontmatter.reply.clone(),
        rendered: record.rendered.clone(),
        path: session_approval_path(paths, session_id, &record.frontmatter.id)
            .display()
            .to_string(),
    })
}

fn approval_within_retention(payload: &InboxApprovalPayload, retention_days: u16) -> bool {
    if payload.status == "pending" {
        return true;
    }
    let cutoff = OffsetDateTime::now_utc() - time::Duration::days(i64::from(retention_days));
    let reference = payload
        .resolved_at
        .as_deref()
        .or(Some(payload.requested_at.as_str()));
    let Some(reference) = reference else {
        return false;
    };
    OffsetDateTime::parse(reference, &Rfc3339)
        .map(|value| value >= cutoff)
        .unwrap_or(false)
}

fn build_inbox_index(
    paths: &AllbertPaths,
    retention_days: u16,
) -> Result<HashMap<String, InboxApprovalPayload>, DaemonError> {
    let mut index = HashMap::new();
    if !paths.sessions.exists() {
        return Ok(index);
    }
    for entry in fs::read_dir(&paths.sessions)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let session_id = entry.file_name().to_string_lossy().to_string();
        if session_id.starts_with('.') {
            continue;
        }
        let approvals_dir = session_approvals_dir(paths, &session_id);
        if !approvals_dir.is_dir() {
            continue;
        }
        for approval_entry in fs::read_dir(&approvals_dir)? {
            let approval_entry = approval_entry?;
            if !approval_entry.file_type()?.is_file() {
                continue;
            }
            if approval_entry
                .path()
                .extension()
                .and_then(|value| value.to_str())
                != Some("md")
            {
                continue;
            }
            let Some(stem) = approval_entry
                .path()
                .file_stem()
                .and_then(|value| value.to_str())
                .map(|value| value.to_string())
            else {
                continue;
            };
            let Some(record) = load_pending_approval(paths, &session_id, &stem)? else {
                continue;
            };
            let payload = pending_approval_to_inbox_payload(paths, &session_id, &record)?;
            if approval_within_retention(&payload, retention_days) {
                index.insert(payload.id.clone(), payload);
            }
        }
    }
    Ok(index)
}

fn rebuild_inbox_index(state: &SharedState) -> Result<(), DaemonError> {
    let retention_days = state.approval_inbox_retention_days.load(Ordering::SeqCst) as u16;
    let index = build_inbox_index(&state.paths, retention_days)?;
    *state.inbox_index.lock().unwrap() = index;
    Ok(())
}

fn list_inbox_entries(state: &SharedState, query: InboxQueryPayload) -> Vec<InboxApprovalPayload> {
    let mut approvals = state
        .inbox_index
        .lock()
        .unwrap()
        .values()
        .cloned()
        .collect::<Vec<_>>();
    approvals.retain(|approval| {
        if !query.include_resolved && approval.status != "pending" {
            return false;
        }
        if let Some(identity) = query.identity.as_deref() {
            if approval.identity_id.as_deref() != Some(identity) {
                return false;
            }
        }
        if let Some(kind) = query.kind.as_deref() {
            if approval.kind != kind {
                return false;
            }
        }
        true
    });
    approvals.sort_by(|a, b| b.requested_at.cmp(&a.requested_at));
    approvals
}

fn lookup_approval_by_id(
    paths: &AllbertPaths,
    approval_id: &str,
) -> Result<Option<ApprovalLookup>, DaemonError> {
    if !paths.sessions.exists() {
        return Ok(None);
    }
    for entry in fs::read_dir(&paths.sessions)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let session_id = entry.file_name().to_string_lossy().to_string();
        if session_id.starts_with('.') {
            continue;
        }
        let Some(record) = load_pending_approval(paths, &session_id, approval_id)? else {
            continue;
        };
        let payload = pending_approval_to_inbox_payload(paths, &session_id, &record)?;
        return Ok(Some(ApprovalLookup { payload }));
    }
    Ok(None)
}

fn show_inbox_entry(
    state: &SharedState,
    approval_id: &str,
) -> Result<Option<InboxApprovalPayload>, DaemonError> {
    if let Some(payload) = state.inbox_index.lock().unwrap().get(approval_id).cloned() {
        return Ok(Some(payload));
    }
    Ok(lookup_approval_by_id(&state.paths, approval_id)?.map(|lookup| lookup.payload))
}

fn approval_visible_to_resolver(
    payload: &InboxApprovalPayload,
    resolver_identity_id: Option<&str>,
) -> bool {
    match (payload.identity_id.as_deref(), resolver_identity_id) {
        (Some(expected), Some(actual)) => expected == actual,
        (Some(_), None) => false,
        _ => true,
    }
}

fn decision_payload_for_accept(accept: bool) -> ConfirmDecisionPayload {
    if accept {
        ConfirmDecisionPayload::AllowOnce
    } else {
        ConfirmDecisionPayload::Deny
    }
}

fn resolution_status(accept: bool) -> PendingApprovalStatus {
    if accept {
        PendingApprovalStatus::Accepted
    } else {
        PendingApprovalStatus::Rejected
    }
}

fn local_operator_identity_id(paths: &AllbertPaths) -> Result<Option<String>, DaemonError> {
    Ok(Some(
        ensure_identity_record(paths).map_err(map_kernel_error)?.id,
    ))
}

fn resolver_key(channel: ChannelKind, sender_id: Option<&str>) -> String {
    let sender = sender_id.unwrap_or("local");
    format!("{}:{sender}", channel_label(channel))
}

fn resolver_for_connection(
    paths: &AllbertPaths,
    client_kind: allbert_proto::ClientKind,
    session: Option<&Arc<SessionHandle>>,
) -> Result<ApprovalResolver, DaemonError> {
    if let Some(session) = session {
        return Ok(ApprovalResolver {
            identity_id: session.identity_id().or(local_operator_identity_id(paths)?),
            resolver_key: resolver_key(session.channel(), session.sender_id().as_deref()),
        });
    }
    let channel = match client_kind {
        allbert_proto::ClientKind::Cli | allbert_proto::ClientKind::Test => ChannelKind::Cli,
        allbert_proto::ClientKind::Repl => ChannelKind::Repl,
        allbert_proto::ClientKind::Jobs => ChannelKind::Jobs,
    };
    Ok(ApprovalResolver {
        identity_id: local_operator_identity_id(paths)?,
        resolver_key: resolver_key(channel, Some(LOCAL_REPL_SENDER)),
    })
}

fn resolver_for_telegram_sender(
    paths: &AllbertPaths,
    sender_id: &str,
) -> Result<ApprovalResolver, DaemonError> {
    Ok(ApprovalResolver {
        identity_id: resolve_identity_id(paths, ChannelKind::Telegram, Some(sender_id))?,
        resolver_key: resolver_key(ChannelKind::Telegram, Some(sender_id)),
    })
}

fn set_session_pending_approval(
    paths: &AllbertPaths,
    session_id: &str,
    pending_approvals: Vec<String>,
) -> Result<(), DaemonError> {
    let Some(mut snapshot) = load_session_snapshot(paths, session_id)? else {
        return Ok(());
    };
    snapshot.meta.set_pending_approvals(pending_approvals);
    persist_session_meta(paths, &snapshot.meta).map_err(map_kernel_error)
}

fn append_session_pending_approval(
    paths: &AllbertPaths,
    session_id: &str,
    approval_id: &str,
) -> Result<(), DaemonError> {
    let Some(mut snapshot) = load_session_snapshot(paths, session_id)? else {
        return Ok(());
    };
    let mut pending_approvals = snapshot.meta.pending_approvals();
    if !pending_approvals.iter().any(|id| id == approval_id) {
        pending_approvals.push(approval_id.to_string());
    }
    snapshot.meta.set_pending_approvals(pending_approvals);
    persist_session_meta(paths, &snapshot.meta).map_err(map_kernel_error)
}

fn resolve_pending_approval(
    paths: &AllbertPaths,
    session_id: &str,
    approval_id: &str,
    status: PendingApprovalStatus,
    resolver: Option<String>,
    reply: Option<String>,
) -> Result<(), DaemonError> {
    let Some(mut record) = load_pending_approval(paths, session_id, approval_id)? else {
        return Ok(());
    };
    record.frontmatter.status = status;
    record.frontmatter.resolved_at = Some(now_rfc3339_fallback());
    record.frontmatter.resolver = resolver;
    record.frontmatter.reply = reply;
    write_pending_approval(paths, &record)?;
    let mut pending = load_session_snapshot(paths, session_id)?
        .map(|snapshot| snapshot.meta.pending_approvals())
        .unwrap_or_default();
    pending.retain(|entry| entry != approval_id);
    set_session_pending_approval(paths, session_id, pending)?;
    Ok(())
}

async fn arm_session_cost_override(
    state: &SharedState,
    session_id: &str,
    sender_id: Option<&str>,
    reason: String,
) -> Result<(), DaemonError> {
    let session = get_or_create_session(
        state,
        ChannelKind::Telegram,
        session_id.to_string(),
        sender_id.map(|value| value.to_string()),
    )
    .await?;
    let mut kernel = session.kernel.lock().await;
    kernel.set_cost_override(reason);
    Ok(())
}

async fn handle_live_approval_resolution(
    state: &SharedState,
    payload: &InboxApprovalPayload,
    live: Option<LiveApproval>,
    accept: bool,
    reason: Option<String>,
) -> Result<(bool, Option<String>), DaemonError> {
    match live {
        Some(LiveApproval::Tool { reply }) => {
            let _ = reply.send(decision_payload_for_accept(accept));
            Ok((true, None))
        }
        Some(LiveApproval::CostCap {
            session_id,
            sender_id,
            chat_id,
            input,
        }) => {
            if !accept {
                return Ok((false, Some("cost-cap override rejected".into())));
            }
            let override_reason = reason.unwrap_or_else(|| "inbox approval".into());
            arm_session_cost_override(state, &session_id, Some(&sender_id), override_reason)
                .await?;
            let runtime = { state.telegram_runtime.lock().unwrap().clone() };
            if let Some(runtime) = runtime {
                let session = get_or_create_session(
                    state,
                    ChannelKind::Telegram,
                    session_id.clone(),
                    Some(sender_id.clone()),
                )
                .await?;
                let runtime_clone = runtime.clone();
                let state_clone = state.clone();
                state.tasks.spawn(async move {
                    if let Err(error) = runtime_clone
                        .clone()
                        .run_turn(session, chat_id, input)
                        .await
                    {
                        runtime_clone.record_error(format!("telegram inbox retry failed: {error}"));
                        let _ = append_log_line(
                            &state_clone.log_path,
                            &format!("telegram inbox retry failed: {error}"),
                        );
                    }
                });
                Ok((
                    true,
                    Some("daily cost override armed and blocked turn retried".into()),
                ))
            } else {
                Ok((
                    false,
                    Some(
                        "daily cost override armed; resend the blocked request to continue".into(),
                    ),
                ))
            }
        }
        Some(LiveApproval::JobRetry { job_name }) => {
            if !accept {
                return Ok((false, Some("job approval rejected".into())));
            }
            let note = format!("queued an immediate retry for job `{job_name}`");
            let retry_name = job_name.clone();
            let state_clone = state.clone();
            state.tasks.spawn(async move {
                let defaults = state_clone.default_config.read().await.clone();
                if let Err(error) = run_named_job(&state_clone, &defaults, &retry_name).await {
                    let _ = append_log_line(
                        &state_clone.log_path,
                        &format!("job approval retry failed for {retry_name}: {error}"),
                    );
                }
            });
            Ok((true, Some(note)))
        }
        None if payload.kind == "cost-cap-override" && accept => {
            let override_reason = reason.unwrap_or_else(|| "inbox approval".into());
            arm_session_cost_override(
                state,
                &payload.session_id,
                Some(&payload.sender),
                override_reason,
            )
            .await?;
            Ok((
                false,
                Some("daily cost override armed for the next turn on this session".into()),
            ))
        }
        None if payload.kind == "job-approval" && accept => {
            let job_name = payload.sender.clone();
            let note = format!("queued an immediate retry for job `{job_name}`");
            let retry_name = job_name.clone();
            let state_clone = state.clone();
            state.tasks.spawn(async move {
                let defaults = state_clone.default_config.read().await.clone();
                if let Err(error) = run_named_job(&state_clone, &defaults, &retry_name).await {
                    let _ = append_log_line(
                        &state_clone.log_path,
                        &format!("job approval retry failed for {retry_name}: {error}"),
                    );
                }
            });
            Ok((true, Some(note)))
        }
        None if payload.kind == "tool-approval" => Ok((
            false,
            Some("approval recorded, but the original turn is no longer active".into()),
        )),
        None => Ok((false, None)),
    }
}

async fn resolve_inbox_approval_for_actor(
    state: &SharedState,
    resolver: &ApprovalResolver,
    approval_id: &str,
    accept: bool,
    reason: Option<String>,
) -> Result<InboxResolveResultPayload, DaemonError> {
    let Some(lookup) = lookup_approval_by_id(&state.paths, approval_id)? else {
        return Err(DaemonError::Protocol(format!(
            "approval not found: {approval_id}"
        )));
    };
    if !approval_visible_to_resolver(&lookup.payload, resolver.identity_id.as_deref()) {
        return Err(DaemonError::Protocol(format!(
            "approval `{approval_id}` belongs to a different identity"
        )));
    }
    if lookup.payload.status != "pending" {
        return Ok(InboxResolveResultPayload {
            approval_id: approval_id.to_string(),
            status: lookup.payload.status,
            resumed_live_turn: false,
            note: Some("approval was already resolved".into()),
        });
    }

    let reply = reason
        .clone()
        .or_else(|| Some(format!("{:?}", decision_payload_for_accept(accept))));
    resolve_pending_approval(
        &state.paths,
        &lookup.payload.session_id,
        approval_id,
        resolution_status(accept),
        Some(resolver.resolver_key.clone()),
        reply,
    )?;
    rebuild_inbox_index(state)?;
    let live = state.live_approvals.lock().unwrap().remove(approval_id);
    let (resumed_live_turn, note) =
        handle_live_approval_resolution(state, &lookup.payload, live, accept, reason).await?;
    Ok(InboxResolveResultPayload {
        approval_id: approval_id.to_string(),
        status: if accept {
            "accepted".into()
        } else {
            "rejected".into()
        },
        resumed_live_turn,
        note,
    })
}

fn spawn_passive_approval_timeout(
    state: &SharedState,
    session_id: String,
    approval_id: String,
    timeout_s: u64,
) {
    let state = state.clone();
    let tasks = state.tasks.clone();
    tasks.spawn(async move {
        tokio::time::sleep(Duration::from_secs(timeout_s)).await;
        let should_timeout = lookup_approval_by_id(&state.paths, &approval_id)
            .ok()
            .flatten()
            .map(|lookup| lookup.payload.status == "pending")
            .unwrap_or(false);
        if should_timeout {
            let _ = resolve_pending_approval(
                &state.paths,
                &session_id,
                &approval_id,
                PendingApprovalStatus::Timeout,
                Some("timeout".into()),
                Some("confirm-timeout".into()),
            );
            let _ = rebuild_inbox_index(&state);
            state.live_approvals.lock().unwrap().remove(&approval_id);
        }
    });
}

fn append_turn_record(
    paths: &AllbertPaths,
    session_id: &str,
    channel: ChannelKind,
    record: &CompletedTurnRecord,
) -> Result<(), std::io::Error> {
    let path = session_turns_path(paths, session_id);
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(file, "## {}", now_rfc3339_fallback())?;
    writeln!(file, "- channel: {}", channel_label(channel))?;
    writeln!(file, "- cost_delta_usd: {:.6}", record.cost_delta_usd)?;
    writeln!(file)?;
    writeln!(file, "### user")?;
    writeln!(file)?;
    writeln!(file, "{}", record.user_input.trim())?;
    writeln!(file)?;
    if !record.user_attachments.is_empty() {
        writeln!(file, "### user attachments")?;
        writeln!(file)?;
        for attachment in &record.user_attachments {
            let kind = match attachment.kind {
                ChatAttachmentKind::Image => "image",
                ChatAttachmentKind::File => "file",
                ChatAttachmentKind::Audio => "audio",
                ChatAttachmentKind::Other => "attachment",
            };
            writeln!(
                file,
                "- {}: {}{}",
                kind,
                attachment.path.display(),
                attachment
                    .mime_type
                    .as_ref()
                    .map(|value| format!(" ({value})"))
                    .unwrap_or_default()
            )?;
        }
        writeln!(file)?;
    }
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
    if content.len() <= limit {
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

fn reconcile_pending_approvals(paths: &AllbertPaths) -> Result<(), DaemonError> {
    let now = OffsetDateTime::now_utc();
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
        let mut keep_pending = Vec::new();
        for approval_id in snapshot.meta.pending_approvals() {
            let Some(record) = load_pending_approval(paths, &session_id, &approval_id)? else {
                continue;
            };
            if record.frontmatter.status != PendingApprovalStatus::Pending {
                continue;
            }
            let expires_at = OffsetDateTime::parse(&record.frontmatter.expires_at, &Rfc3339)
                .unwrap_or_else(|_| now - time::Duration::seconds(1));
            if expires_at <= now {
                resolve_pending_approval(
                    paths,
                    &session_id,
                    &approval_id,
                    PendingApprovalStatus::Timeout,
                    Some("daemon-restart".into()),
                    Some("confirm-timeout".into()),
                )?;
                continue;
            }
            keep_pending.push(approval_id);
        }
        set_session_pending_approval(paths, &session_id, keep_pending)?;
    }
    Ok(())
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

fn channel_adapter(channel: Arc<LocalIpcChannel>) -> FrontendAdapter {
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
            .send(OutboundMessage::Event(ServerMessage::Event(
                map_kernel_event(event),
            )))
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
            approval_id: prompt.request_id,
            program: prompt.program,
            args: prompt.args,
            cwd: prompt.cwd.map(|path| path.display().to_string()),
            rendered: prompt.rendered,
            expires_at: prompt.expires_at,
        };
        self.outbound
            .send(OutboundMessage::Confirm(payload, tx))
            .map_err(|_| ChannelError::Disconnected)?;

        match rx.await.map_err(|_| ChannelError::Disconnected)? {
            ConfirmDecisionPayload::AllowOnce => Ok(ConfirmOutcome::AllowOnce),
            ConfirmDecisionPayload::AllowSession => Ok(ConfirmOutcome::AllowSession),
            ConfirmDecisionPayload::Deny => Ok(ConfirmOutcome::Deny),
            ConfirmDecisionPayload::Timeout => Ok(ConfirmOutcome::Timeout),
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
            Ok(ConfirmOutcome::Timeout) => ConfirmDecision::Timeout,
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

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), DaemonError> {
    let parent = path
        .parent()
        .ok_or_else(|| DaemonError::Protocol(format!("path has no parent: {}", path.display())))?;
    fs::create_dir_all(parent)?;
    let tmp = parent.join(format!(
        ".{}.tmp-{}",
        path.file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("write"),
        uuid::Uuid::new_v4().simple()
    ));
    {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

fn current_host() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("COMPUTERNAME"))
        .unwrap_or_else(|_| "unknown-host".into())
}

#[cfg(unix)]
fn pid_is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn pid_is_alive(_pid: u32) -> bool {
    false
}

fn load_daemon_lock(paths: &AllbertPaths) -> Result<Option<DaemonLockRecord>, DaemonError> {
    if !paths.daemon_lock.exists() {
        return Ok(None);
    }
    let raw = fs::read(&paths.daemon_lock)?;
    let record: DaemonLockRecord = serde_json::from_slice(&raw)?;
    Ok(Some(record))
}

fn acquire_daemon_lock(paths: &AllbertPaths) -> Result<DaemonLockRecord, DaemonError> {
    let host = current_host();
    let pid = std::process::id();
    let started_at = now_rfc3339_fallback();
    if let Some(existing) = load_daemon_lock(paths)? {
        if existing.host == host {
            if pid_is_alive(existing.pid) {
                return Err(DaemonError::Protocol(format!(
                    "daemon lock is held by live process pid={} on host={}; remove stale lock only after stopping that daemon",
                    existing.pid, existing.host
                )));
            }
            append_log_line(
                &paths.daemon_log,
                &format!(
                    "stale daemon lock takeover host={} stale_pid={} new_pid={}",
                    host, existing.pid, pid
                ),
            )
            .ok();
        } else {
            return Err(DaemonError::Protocol(format!(
                "daemon lock exists from different host {}; refusing start without manual lock intervention",
                existing.host
            )));
        }
    }
    let record = DaemonLockRecord {
        pid,
        host,
        started_at,
    };
    atomic_write(&paths.daemon_lock, &serde_json::to_vec_pretty(&record)?)
        .map_err(|err| DaemonError::Protocol(format!("write daemon lock: {err}")))?;
    Ok(record)
}

fn release_daemon_lock(paths: &AllbertPaths, expected_pid: Option<u32>) -> Result<(), DaemonError> {
    let Some(record) = load_daemon_lock(paths)? else {
        return Ok(());
    };
    if expected_pid.is_some() && expected_pid != Some(record.pid) {
        return Ok(());
    }
    match fs::remove_file(&paths.daemon_lock) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => return Err(DaemonError::Io(err)),
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

#[cfg(unix)]
fn set_socket_permissions_best_effort(socket_path: &Path) -> Result<(), DaemonError> {
    use std::os::unix::fs::PermissionsExt;

    match std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600)) {
        Ok(()) => Ok(()),
        Err(err) if should_ignore_socket_permission_error(err.kind()) => {
            // Some local-socket backends on macOS refuse chmod on the socket inode itself even
            // when the parent directory is already locked down to 0700. The private parent
            // directory remains the primary access control in that case.
            Ok(())
        }
        Err(err) => Err(DaemonError::Io(err)),
    }
}

#[cfg(unix)]
fn should_ignore_socket_permission_error(kind: std::io::ErrorKind) -> bool {
    matches!(
        kind,
        std::io::ErrorKind::PermissionDenied | std::io::ErrorKind::Unsupported
    )
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

#[cfg(test)]
mod telegram_tests {
    use super::*;
    use std::io::ErrorKind;
    use teloxide::types::{FileId, FileMeta, FileUniqueId};

    fn temp_paths() -> AllbertPaths {
        let root = std::env::temp_dir().join(format!(
            "allbert-telegram-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let paths = AllbertPaths::under(root);
        paths.ensure().expect("paths should be created");
        paths
    }

    fn sample_meta(
        session_id: &str,
        sender_id: Option<&str>,
        last_activity_at: &str,
    ) -> SessionJournalMeta {
        SessionJournalMeta {
            session_id: session_id.into(),
            channel: ChannelKind::Telegram,
            sender_id: sender_id.map(str::to_string),
            identity_id: None,
            started_at: "2026-04-20T00:00:00Z".into(),
            last_activity_at: last_activity_at.into(),
            root_agent_name: "allbert/root".into(),
            last_agent_stack: vec!["allbert/root".into()],
            last_resolved_intent: Some("task".into()),
            intent_history: vec!["task".into()],
            active_skills: Vec::new(),
            ephemeral_memory: Vec::new(),
            model: model_to_payload(&Config::default_template().model),
            turn_count: 1,
            cost_total_usd: 0.0,
            messages: Vec::new(),
            pending_approvals: Vec::new(),
            legacy_pending_approval: None,
        }
    }

    #[test]
    fn telegram_command_parser_covers_control_vocabulary() {
        assert_eq!(parse_telegram_command("/reset"), TelegramCommand::Reset);
        assert_eq!(
            parse_telegram_command("/approve approval-123"),
            TelegramCommand::Approve("approval-123".into())
        );
        assert_eq!(
            parse_telegram_command("/reject approval-456"),
            TelegramCommand::Reject("approval-456".into())
        );
        assert_eq!(
            parse_telegram_command("/override release smoke"),
            TelegramCommand::Override("release smoke".into())
        );
        assert_eq!(
            parse_telegram_command("/start"),
            TelegramCommand::Text("/start".into())
        );
    }

    #[test]
    fn telegram_allowlist_parser_ignores_comments_and_blank_lines() {
        let allowed = parse_telegram_allowed_chats("\n# test\n12345\n-777 # group\n\n  99  \n")
            .expect("allowlist should parse");
        assert!(allowed.contains(&12345));
        assert!(allowed.contains(&-777));
        assert!(allowed.contains(&99));
        assert_eq!(allowed.len(), 3);
    }

    #[test]
    fn telegram_markdown_rendering_chunks_and_escapes() {
        let escaped = escape_telegram_markdown_v2("Hello [team] (v1.0)!");
        assert_eq!(escaped, "Hello \\[team\\] \\(v1\\.0\\)\\!");

        let chunks = chunk_telegram_markdown_v2(&"a".repeat(9000), 4096);
        assert!(chunks.len() >= 3);
        assert!(chunks.iter().all(|chunk| chunk.len() <= 4096));
        assert!(chunks[0].starts_with("1/"));
    }

    #[test]
    fn telegram_session_lookup_prefers_latest_matching_sender() {
        let paths = temp_paths();
        persist_session_meta(
            &paths,
            &sample_meta(
                "telegram-old",
                Some("telegram:1:10"),
                "2026-02-01T00:00:00Z",
            ),
        )
        .expect("old meta should persist");
        persist_session_meta(
            &paths,
            &sample_meta(
                "telegram-recent",
                Some("telegram:1:10"),
                &now_rfc3339_fallback(),
            ),
        )
        .expect("recent meta should persist");
        persist_session_meta(
            &paths,
            &sample_meta(
                "telegram-other",
                Some("telegram:2:20"),
                &now_rfc3339_fallback(),
            ),
        )
        .expect("other meta should persist");

        let selected =
            find_recent_telegram_session(&paths, "telegram:1:10", 30).expect("lookup should work");
        assert_eq!(selected.as_deref(), Some("telegram-recent"));

        std::fs::remove_dir_all(paths.root).ok();
    }

    #[test]
    fn best_telegram_photo_prefers_largest_variant() {
        let small = PhotoSize {
            file: FileMeta {
                id: FileId("small".into()),
                unique_id: FileUniqueId("small-u".into()),
                size: 10,
            },
            width: 100,
            height: 100,
        };
        let large = PhotoSize {
            file: FileMeta {
                id: FileId("large".into()),
                unique_id: FileUniqueId("large-u".into()),
                size: 20,
            },
            width: 800,
            height: 600,
        };

        let options = [small.clone(), large.clone()];
        let selected = best_telegram_photo(&options).expect("photo should be selected");
        assert_eq!(selected, &large);
    }

    #[test]
    fn session_image_paths_live_under_session_artifacts() {
        let paths = temp_paths();
        let artifact = next_session_image_path(&paths, "telegram-42", 7);
        assert_eq!(
            artifact,
            paths
                .sessions
                .join("telegram-42")
                .join("artifacts")
                .join("telegram-photo-7.jpg")
        );

        std::fs::remove_dir_all(paths.root).ok();
    }

    #[cfg(unix)]
    #[test]
    fn socket_permission_step_ignores_permission_denied_and_unsupported() {
        assert!(should_ignore_socket_permission_error(
            ErrorKind::PermissionDenied
        ));
        assert!(should_ignore_socket_permission_error(
            ErrorKind::Unsupported
        ));
        assert!(!should_ignore_socket_permission_error(ErrorKind::Other));
    }
}
