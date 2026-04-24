use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 2;

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
    Telegram,
}

impl ChannelKind {
    pub fn default_session_id(self) -> String {
        match self {
            Self::Repl => "repl-primary".into(),
            Self::Cli => "cli-default".into(),
            Self::Jobs => "jobs-default".into(),
            Self::Telegram => "telegram-default".into(),
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
    pub lock_owner: Option<DaemonLockPayload>,
    pub model_api_key_env: Option<String>,
    pub model_base_url: Option<String>,
    pub model_api_key_visible: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DaemonLockPayload {
    pub pid: u32,
    pub host: String,
    pub started_at: String,
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
    Openai,
    Gemini,
    Ollama,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelConfigPayload {
    pub provider: ProviderKind,
    pub model_id: String,
    pub api_key_env: Option<String>,
    pub base_url: Option<String>,
    pub max_tokens: u32,
    #[serde(default)]
    pub context_window_tokens: u32,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct TokenUsagePayload {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_create_tokens: u64,
    pub total_tokens: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TurnBudgetTelemetry {
    pub limit_usd: f64,
    pub limit_seconds: u64,
    pub remaining_usd: Option<f64>,
    pub remaining_seconds: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryTelemetry {
    pub synopsis_bytes: usize,
    pub ephemeral_bytes: usize,
    pub durable_count: usize,
    pub staged_count: usize,
    pub staged_this_turn: usize,
    pub prefetch_hit_count: usize,
    pub episode_count: usize,
    pub fact_count: usize,
    pub always_eligible_skills: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TelemetrySnapshot {
    pub session_id: String,
    pub channel: ChannelKind,
    pub provider: String,
    pub model: ModelConfigPayload,
    pub context_window_tokens: u32,
    pub context_used_tokens: Option<u64>,
    pub context_percent: Option<f64>,
    pub last_response_usage: Option<TokenUsagePayload>,
    pub session_usage: TokenUsagePayload,
    pub session_cost_usd: f64,
    pub today_cost_usd: f64,
    pub turn_budget: TurnBudgetTelemetry,
    pub memory: MemoryTelemetry,
    pub active_skills: Vec<String>,
    pub last_agent_stack: Vec<String>,
    pub last_resolved_intent: Option<String>,
    pub inbox_count: usize,
    pub trace_enabled: bool,
    pub setup_version: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionResumeEntry {
    pub session_id: String,
    pub channel: ChannelKind,
    pub started_at: String,
    pub last_activity_at: String,
    pub turn_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TurnBudgetOverridePayload {
    pub usd: Option<f64>,
    pub seconds: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChannelRuntimeStatusPayload {
    pub kind: ChannelKind,
    pub running: bool,
    pub queue_depth: Option<usize>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobReportPolicyPayload {
    Always,
    OnFailure,
    OnAnomaly,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JobBudgetPayload {
    pub max_turn_usd: Option<f64>,
    pub max_turn_s: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
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
    pub budget: Option<JobBudgetPayload>,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
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
    Timeout,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConfirmRequestPayload {
    pub request_id: u64,
    pub approval_id: Option<String>,
    pub program: String,
    pub args: Vec<String>,
    pub cwd: Option<String>,
    pub rendered: String,
    pub expires_at: Option<String>,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InboxQueryPayload {
    pub identity: Option<String>,
    pub kind: Option<String>,
    pub include_resolved: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InboxApprovalPayload {
    pub id: String,
    pub session_id: String,
    pub identity_id: Option<String>,
    pub channel: ChannelKind,
    pub sender: String,
    pub agent: String,
    pub tool: String,
    pub request_id: u64,
    pub kind: String,
    pub requested_at: String,
    pub expires_at: String,
    pub status: String,
    pub resolved_at: Option<String>,
    pub resolver: Option<String>,
    pub reply: Option<String>,
    pub rendered: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InboxResolvePayload {
    pub approval_id: String,
    pub accept: bool,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InboxResolveResultPayload {
    pub approval_id: String,
    pub status: String,
    pub resumed_live_turn: bool,
    pub note: Option<String>,
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

#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello(ClientHello),
    Attach(OpenChannel),
    Status,
    SessionStatus,
    SessionTelemetry,
    ListSessions,
    ListInbox(InboxQueryPayload),
    ShowInboxApproval(String),
    ResolveInboxApproval(InboxResolvePayload),
    ForgetSession(String),
    RunTurn(TurnRequest),
    ConfirmReply(ConfirmReplyPayload),
    InputReply(InputReplyPayload),
    GetModel,
    SetModel(ModelConfigPayload),
    SetCostOverride(String),
    SetTurnBudgetOverride(TurnBudgetOverridePayload),
    SetAutoConfirm(bool),
    SetTrace(bool),
    ReloadSessionConfig,
    ListChannelRuntimes,
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

#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum ServerMessage {
    Hello(ServerHello),
    Attached(AttachedChannel),
    Status(DaemonStatus),
    SessionStatus(SessionStatus),
    SessionTelemetry(TelemetrySnapshot),
    Sessions(Vec<SessionResumeEntry>),
    InboxApprovals(Vec<InboxApprovalPayload>),
    InboxApproval(InboxApprovalPayload),
    InboxResolveResult(InboxResolveResultPayload),
    Event(KernelEventPayload),
    ConfirmRequest(ConfirmRequestPayload),
    InputRequest(InputRequestPayload),
    TurnResult(TurnResult),
    Model(ModelConfigPayload),
    ChannelRuntimes(Vec<ChannelRuntimeStatusPayload>),
    Jobs(Vec<JobStatusPayload>),
    Job(JobStatusPayload),
    JobRun(JobRunRecordPayload),
    JobRuns(Vec<JobRunRecordPayload>),
    Ack,
    Error(ProtocolError),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn telemetry_snapshot_json_roundtrip() {
        let snapshot = TelemetrySnapshot {
            session_id: "repl-primary".into(),
            channel: ChannelKind::Repl,
            provider: "ollama".into(),
            model: ModelConfigPayload {
                provider: ProviderKind::Ollama,
                model_id: "gemma4".into(),
                api_key_env: None,
                base_url: Some("http://127.0.0.1:11434".into()),
                max_tokens: 4096,
                context_window_tokens: 8192,
            },
            context_window_tokens: 8192,
            context_used_tokens: Some(1024),
            context_percent: Some(12.5),
            last_response_usage: Some(TokenUsagePayload {
                input_tokens: 900,
                output_tokens: 124,
                cache_read_tokens: 10,
                cache_create_tokens: 2,
                total_tokens: 1036,
            }),
            session_usage: TokenUsagePayload {
                input_tokens: 1900,
                output_tokens: 224,
                cache_read_tokens: 10,
                cache_create_tokens: 2,
                total_tokens: 2136,
            },
            session_cost_usd: 0.0123,
            today_cost_usd: 0.0456,
            turn_budget: TurnBudgetTelemetry {
                limit_usd: 0.5,
                limit_seconds: 120,
                remaining_usd: Some(0.4),
                remaining_seconds: Some(90),
            },
            memory: MemoryTelemetry {
                synopsis_bytes: 512,
                ephemeral_bytes: 128,
                durable_count: 7,
                staged_count: 2,
                staged_this_turn: 1,
                prefetch_hit_count: 3,
                episode_count: 4,
                fact_count: 5,
                always_eligible_skills: vec!["memory-curator".into()],
            },
            active_skills: vec!["memory-curator".into()],
            last_agent_stack: vec!["allbert/root".into()],
            last_resolved_intent: Some("memory_query".into()),
            inbox_count: 1,
            trace_enabled: true,
            setup_version: 4,
        };

        let raw = serde_json::to_string(&ServerMessage::SessionTelemetry(snapshot.clone()))
            .expect("telemetry should serialize");
        let decoded: ServerMessage =
            serde_json::from_str(&raw).expect("telemetry should deserialize");

        assert_eq!(decoded, ServerMessage::SessionTelemetry(snapshot));
    }
}
