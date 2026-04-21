use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ClientKind {
    Cli,
    Repl,
    Jobs,
    Test,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum ChannelKind {
    Cli,
    Repl,
    Jobs,
}

impl ChannelKind {
    pub fn default_session_id(self) -> String {
        match self {
            Self::Repl => "repl-primary".into(),
            Self::Cli => "cli-default".into(),
            Self::Jobs => "jobs-default".into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ClientHello {
    pub protocol_version: u32,
    pub client_kind: ClientKind,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ServerHello {
    pub protocol_version: u32,
    pub daemon_id: String,
    pub pid: u32,
    pub started_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenChannel {
    pub channel: ChannelKind,
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AttachedChannel {
    pub channel: ChannelKind,
    pub session_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DaemonStatus {
    pub daemon_id: String,
    pub pid: u32,
    pub socket_path: String,
    pub started_at: String,
    pub session_count: usize,
    pub trace_enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Anthropic,
    Openrouter,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelConfigPayload {
    pub provider: ProviderKind,
    pub model_id: String,
    pub api_key_env: String,
    pub max_tokens: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SessionStatus {
    pub session_id: String,
    pub provider: String,
    pub model: ModelConfigPayload,
    pub api_key_present: bool,
    pub setup_version: u8,
    pub bootstrap_pending: bool,
    pub trusted_roots: Vec<String>,
    pub skill_count: usize,
    pub trace_enabled: bool,
    pub session_cost_usd: f64,
    pub today_cost_usd: f64,
    pub root_agent_name: String,
    pub last_agent_stack: Vec<String>,
    pub last_resolved_intent: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionResumeEntry {
    pub session_id: String,
    pub channel: ChannelKind,
    pub started_at: String,
    pub last_activity_at: String,
    pub turn_count: u32,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobReportPolicyPayload {
    Always,
    OnFailure,
    OnAnomaly,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JobDefinitionPayload {
    pub name: String,
    pub description: String,
    pub enabled: bool,
    pub schedule: String,
    pub skills: Vec<String>,
    pub timezone: Option<String>,
    pub model: Option<ModelConfigPayload>,
    pub allowed_tools: Vec<String>,
    pub timeout_s: Option<u64>,
    pub report: Option<JobReportPolicyPayload>,
    pub max_turns: Option<u32>,
    pub session_name: Option<String>,
    pub memory_prefetch: Option<bool>,
    pub prompt: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JobStatePayload {
    pub paused: bool,
    pub last_run_at: Option<String>,
    pub next_due_at: Option<String>,
    pub failure_streak: u32,
    pub running: bool,
    pub last_run_id: Option<String>,
    pub last_outcome: Option<String>,
    pub last_stop_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JobStatusPayload {
    pub definition: JobDefinitionPayload,
    pub state: JobStatePayload,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JobRunRecordPayload {
    pub run_id: String,
    pub job_name: String,
    pub session_id: String,
    pub started_at: String,
    pub ended_at: String,
    pub outcome: String,
    pub cost_usd: f64,
    pub skills_attached: Vec<String>,
    pub stop_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TurnRequest {
    pub input: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TurnResult {
    pub hit_turn_limit: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConfirmDecisionPayload {
    Deny,
    AllowOnce,
    AllowSession,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConfirmRequestPayload {
    pub request_id: u64,
    pub program: String,
    pub args: Vec<String>,
    pub cwd: Option<String>,
    pub rendered: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConfirmReplyPayload {
    pub request_id: u64,
    pub decision: ConfirmDecisionPayload,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InputRequestPayload {
    pub request_id: u64,
    pub prompt: String,
    pub allow_empty: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum InputResponsePayload {
    Submitted(String),
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InputReplyPayload {
    pub request_id: u64,
    pub response: InputResponsePayload,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", content = "payload", rename_all = "snake_case")]
pub enum KernelEventPayload {
    SkillTier1Surfaced {
        skill_name: String,
    },
    SkillTier2Activated {
        skill_name: String,
    },
    SkillTier3Referenced {
        skill_name: String,
        path: String,
    },
    AssistantText(String),
    JobFailed {
        job_name: String,
        run_id: String,
        ended_at: String,
        stop_reason: Option<String>,
    },
    ToolCall {
        name: String,
        input: Value,
    },
    ToolResult {
        name: String,
        ok: bool,
        content: String,
    },
    Cost {
        usd_estimate: f64,
    },
    TurnDone {
        hit_turn_limit: bool,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello(ClientHello),
    Attach(OpenChannel),
    Status,
    SessionStatus,
    ListSessions,
    ForgetSession(String),
    RunTurn(TurnRequest),
    ConfirmReply(ConfirmReplyPayload),
    InputReply(InputReplyPayload),
    GetModel,
    SetModel(ModelConfigPayload),
    SetAutoConfirm(bool),
    SetTrace(bool),
    ReloadSessionConfig,
    ListJobs,
    GetJob(String),
    UpsertJob(JobDefinitionPayload),
    PauseJob(String),
    ResumeJob(String),
    RunJob(String),
    RemoveJob(String),
    SweepJobs(Option<String>),
    Shutdown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum ServerMessage {
    Hello(ServerHello),
    Attached(AttachedChannel),
    Status(DaemonStatus),
    SessionStatus(SessionStatus),
    Sessions(Vec<SessionResumeEntry>),
    Event(KernelEventPayload),
    ConfirmRequest(ConfirmRequestPayload),
    InputRequest(InputRequestPayload),
    TurnResult(TurnResult),
    Model(ModelConfigPayload),
    Jobs(Vec<JobStatusPayload>),
    Job(JobStatusPayload),
    JobRun(JobRunRecordPayload),
    JobRuns(Vec<JobRunRecordPayload>),
    Ack,
    Error(ProtocolError),
}
