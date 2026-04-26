use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const MIN_PROTOCOL_VERSION: u32 = 2;
pub const PROTOCOL_VERSION: u32 = 6;

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

pub fn is_valid_otlp_trace_id(value: &str) -> bool {
    is_valid_lower_hex_id(value, 32)
}

pub fn is_valid_otlp_span_id(value: &str) -> bool {
    is_valid_lower_hex_id(value, 16)
}

fn is_valid_lower_hex_id(value: &str, len: usize) -> bool {
    value.len() == len
        && value.bytes().any(|byte| byte != b'0')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum ActivityPhase {
    #[default]
    Idle,
    Queued,
    PreparingContext,
    ClassifyingIntent,
    CallingModel,
    StreamingResponse,
    CallingTool,
    WaitingForApproval,
    WaitingForInput,
    RunningValidation,
    RunningScript,
    Training,
    Diagnosing,
    Finalizing,
    Error,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ActivitySnapshot {
    pub phase: ActivityPhase,
    pub label: String,
    pub started_at: String,
    pub elapsed_ms: u64,
    pub session_id: String,
    pub channel: ChannelKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skill_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_progress_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stuck_hint: Option<String>,
    #[serde(default)]
    pub next_actions: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", content = "payload", rename_all = "snake_case")]
pub enum ApprovalContext {
    ToolConfirm {
        tool_name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
        argument_summary: String,
        why: String,
    },
    CostCapOverride {
        requested_increase: String,
        current_daily_total: String,
        configured_cap: String,
        reason: String,
    },
    JobApproval {
        job_kind: String,
        schedule: String,
        next_fire_time: String,
        recurrence_summary: String,
    },
    PatchApproval {
        branch: String,
        validation_status: String,
        file_stats: String,
        artifact_path: String,
        diff_preview: Vec<String>,
    },
    MemoryPromotion {
        preview: String,
        source: String,
        supersession_hint: String,
    },
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
pub struct AdapterTelemetry {
    pub active_id: String,
    pub base_model: String,
    pub provenance: String,
    pub trained_at: String,
    pub golden_pass_rate: f64,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adapter: Option<AdapterTelemetry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_activity: Option<ActivitySnapshot>,
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
pub enum SpanKind {
    Internal,
    Client,
    Server,
    Producer,
    Consumer,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SpanStatus {
    Ok,
    Error { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SpanEvent {
    pub timestamp: DateTime<Utc>,
    pub name: String,
    pub attributes: BTreeMap<String, AttributeValue>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum AttributeValue {
    String(String),
    Int(i64),
    Float(f64),
    Bool(bool),
    StringArray(Vec<String>),
    IntArray(Vec<i64>),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Span {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    pub session_id: String,
    pub trace_id: String,
    pub name: String,
    pub kind: SpanKind,
    pub started_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    pub status: SpanStatus,
    #[serde(default)]
    pub attributes: BTreeMap<String, AttributeValue>,
    #[serde(default)]
    pub events: Vec<SpanEvent>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TraceSessionSummary {
    pub session_id: String,
    pub span_count: u64,
    pub root_span_count: u64,
    pub started_at: DateTime<Utc>,
    pub last_touched_at: DateTime<Utc>,
    pub total_duration_ms: u64,
    pub bytes: u64,
    pub has_rotated_archives: bool,
    pub truncated_count: u64,
}

pub const ADAPTER_MANIFEST_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterManifestSchemaError {
    pub schema_version: u32,
    pub supported_schema_version: u32,
}

impl std::fmt::Display for AdapterManifestSchemaError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "unsupported adapter manifest schema version {}; supported version is {}",
            self.schema_version, self.supported_schema_version
        )
    }
}

impl std::error::Error for AdapterManifestSchemaError {}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BaseModelRef {
    pub provider: ProviderKind,
    pub model_id: String,
    pub model_digest: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdapterHyperparameters {
    pub rank: u32,
    pub alpha: u32,
    pub learning_rate: f64,
    pub max_steps: u32,
    pub batch_size: u32,
    pub seed: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdapterResourceCost {
    pub compute_wall_seconds: u64,
    pub peak_resident_mb: u64,
    pub usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdapterEvalSummary {
    pub golden_pass_rate: f64,
    pub loss_final: f64,
    pub loss_curve_path: String,
    pub behavioral_diff_path: String,
    pub behavioral_samples: u32,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum AdapterProvenance {
    SelfTrained,
    External,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum AdapterWeightsFormat {
    SafetensorsLora,
    GgufLora,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum AdapterOverallStatus {
    ReadyForReview,
    NeedsAttention,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdapterManifest {
    #[serde(default = "default_adapter_manifest_schema_version")]
    pub schema_version: u32,
    pub adapter_id: String,
    pub provenance: AdapterProvenance,
    pub trainer_backend: String,
    pub base_model: BaseModelRef,
    pub training_run_id: String,
    pub corpus_digest: String,
    pub weights_format: AdapterWeightsFormat,
    pub weights_size_bytes: u64,
    pub hyperparameters: AdapterHyperparameters,
    pub resource_cost: AdapterResourceCost,
    pub eval_summary: AdapterEvalSummary,
    pub overall: AdapterOverallStatus,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accepted_at: Option<DateTime<Utc>>,
}

impl AdapterManifest {
    pub fn validate_schema_version(&self) -> Result<(), AdapterManifestSchemaError> {
        if self.schema_version == ADAPTER_MANIFEST_SCHEMA_VERSION {
            Ok(())
        } else {
            Err(AdapterManifestSchemaError {
                schema_version: self.schema_version,
                supported_schema_version: ADAPTER_MANIFEST_SCHEMA_VERSION,
            })
        }
    }
}

fn default_adapter_manifest_schema_version() -> u32 {
    ADAPTER_MANIFEST_SCHEMA_VERSION
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ActiveAdapter {
    pub adapter_id: String,
    pub base_model: BaseModelRef,
    pub activated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdapterTrainingProgressPayload {
    pub run_id: String,
    pub phase: String,
    pub step: u32,
    pub total_steps: u32,
    pub elapsed_seconds: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub eta_seconds: Option<u64>,
    pub peak_resident_mb: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_loss: Option<f64>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum AdapterTrainingFinalStatus {
    Succeeded,
    Cancelled,
    Failed,
    CapExceeded,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterTrainingFinalPayload {
    pub run_id: String,
    pub status: AdapterTrainingFinalStatus,
    pub ended_at: DateTime<Utc>,
    pub manifest_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdaptersStatusPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active: Option<ActiveAdapter>,
    pub today_compute_wall_seconds: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compute_cap_wall_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remaining_compute_wall_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_training_run_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_training_status: Option<AdapterTrainingFinalStatus>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdaptersHistoryEntry {
    pub adapter_id: String,
    pub action: String,
    pub at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterActivateRequest {
    pub adapter_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub override_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterRemoveRequest {
    pub adapter_id: String,
    pub force: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdaptersHistoryRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterTrainingStartRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backend: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub override_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterTrainingCancelRequest {
    pub run_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterInstallExternalRequest {
    pub path: String,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_activity: Option<ActivitySnapshot>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<ApprovalContext>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub patch: Option<PatchApprovalPayload>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<ApprovalContext>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PatchApprovalPayload {
    pub source_checkout: String,
    pub branch: String,
    pub worktree_path: String,
    pub validation: String,
    pub artifact_path: String,
    pub overall: String,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosisRunRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lookback_days: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remediation: Option<DiagnosisRemediationRequestPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosisRemediationRequestPayload {
    pub kind: String,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosisListRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosisShowRequest {
    pub diagnosis_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiagnosisReportSummaryPayload {
    pub schema_version: u32,
    pub diagnosis_id: String,
    pub session_id: String,
    pub created_at: DateTime<Utc>,
    pub selected_session_ids: Vec<String>,
    pub classification: String,
    pub confidence: f32,
    pub rationale: String,
    pub bounds: Value,
    pub truncation: Value,
    pub warnings: Vec<String>,
    pub span_count: usize,
    pub event_count: usize,
    pub report_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remediation: Option<DiagnosisRemediationSummaryPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosisRemediationSummaryPayload {
    pub kind: String,
    pub reason: String,
    pub status: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiagnosisReportPayload {
    pub summary: DiagnosisReportSummaryPayload,
    pub report_markdown: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosisStartedPayload {
    pub session_id: String,
    pub diagnosis_id_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UtilityEnableRequest {
    pub utility_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UtilityCatalogEntryPayload {
    pub id: String,
    pub name: String,
    pub description: String,
    pub executable_candidates: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub installed_path: Option<String>,
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path_canonical: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub help_summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verified_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exec_note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnabledUtilityPayload {
    pub id: String,
    pub path: String,
    pub path_canonical: String,
    pub version: String,
    pub help_summary: String,
    pub enabled_at: String,
    pub verified_at: String,
    pub status: String,
    pub size_bytes: u64,
    pub modified_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UtilitiesDoctorPayload {
    pub manifest_path: String,
    pub entries: Vec<EnabledUtilityPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UnixPipeRunSummaryPayload {
    pub ok: bool,
    pub timed_out: bool,
    pub cap_violated: bool,
    pub stdout: String,
    pub stdout_bytes: usize,
    pub stdout_truncated: bool,
    pub lossy_utf8: bool,
    pub stages: Vec<UnixPipeStageSummaryPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UnixPipeStageSummaryPayload {
    pub utility_id: String,
    pub exit_code: Option<i32>,
    pub stdout_bytes: usize,
    pub stderr_bytes: usize,
    pub stderr_summary: String,
    pub stderr_truncated: bool,
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
    ActivitySnapshot,
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
    TraceSubscribe {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
    },
    TraceUnsubscribe {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
    },
    TraceShow {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
    },
    TraceShowSpan {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        span_id: String,
    },
    TraceList,
    AdaptersList,
    AdaptersShow(String),
    AdaptersActivate(AdapterActivateRequest),
    AdaptersDeactivate,
    AdaptersRemove(AdapterRemoveRequest),
    AdaptersStatus,
    AdaptersHistory(AdaptersHistoryRequest),
    AdaptersTrainingStart(AdapterTrainingStartRequest),
    AdaptersTrainingCancel(AdapterTrainingCancelRequest),
    AdaptersInstallExternal(AdapterInstallExternalRequest),
    DiagnoseRun(DiagnosisRunRequest),
    DiagnoseList(DiagnosisListRequest),
    DiagnoseShow(DiagnosisShowRequest),
    UtilitiesDiscover,
    UtilitiesList,
    UtilitiesShow(String),
    UtilitiesEnable(UtilityEnableRequest),
    UtilitiesDisable(String),
    UtilitiesDoctor,
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
    ActivitySnapshot(ActivitySnapshot),
    ActivityUpdate(ActivitySnapshot),
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
    TraceSubscribed { session_id: String },
    TraceSpan(Span),
    TraceSpans(Vec<Span>),
    TraceSpanDetail(Span),
    TraceSessions(Vec<TraceSessionSummary>),
    Adapters(Vec<AdapterManifest>),
    Adapter(AdapterManifest),
    ActiveAdapter(Option<ActiveAdapter>),
    AdaptersStatus(AdaptersStatusPayload),
    AdaptersHistory(Vec<AdaptersHistoryEntry>),
    AdapterTrainingProgress(AdapterTrainingProgressPayload),
    AdapterTrainingFinal(AdapterTrainingFinalPayload),
    DiagnosisStarted(DiagnosisStartedPayload),
    Diagnosis(DiagnosisReportSummaryPayload),
    Diagnoses(Vec<DiagnosisReportSummaryPayload>),
    DiagnosisReport(DiagnosisReportPayload),
    UtilityCatalog(Vec<UtilityCatalogEntryPayload>),
    Utility(UtilityCatalogEntryPayload),
    EnabledUtilities(Vec<EnabledUtilityPayload>),
    UtilitiesDoctor(UtilitiesDoctorPayload),
    UnixPipeRun(UnixPipeRunSummaryPayload),
    Ack,
    Error(ProtocolError),
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    fn ts(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).expect("fixture timestamp should be valid")
    }

    fn fixture_adapter_manifest() -> AdapterManifest {
        AdapterManifest {
            schema_version: ADAPTER_MANIFEST_SCHEMA_VERSION,
            adapter_id: "20260501-personality-1".into(),
            provenance: AdapterProvenance::SelfTrained,
            trainer_backend: "fake".into(),
            base_model: BaseModelRef {
                provider: ProviderKind::Ollama,
                model_id: "gemma4".into(),
                model_digest: "sha256:base".into(),
            },
            training_run_id: "20260501-1842-lora".into(),
            corpus_digest: "sha256:corpus".into(),
            weights_format: AdapterWeightsFormat::SafetensorsLora,
            weights_size_bytes: 128,
            hyperparameters: AdapterHyperparameters {
                rank: 8,
                alpha: 16,
                learning_rate: 0.0001,
                max_steps: 200,
                batch_size: 4,
                seed: 42,
            },
            resource_cost: AdapterResourceCost {
                compute_wall_seconds: 932,
                peak_resident_mb: 6144,
                usd: 0.0,
            },
            eval_summary: AdapterEvalSummary {
                golden_pass_rate: 0.92,
                loss_final: 0.81,
                loss_curve_path: "/tmp/loss-curve.txt".into(),
                behavioral_diff_path: "/tmp/behavioral-diff.md".into(),
                behavioral_samples: 24,
            },
            overall: AdapterOverallStatus::ReadyForReview,
            created_at: ts(1_777_657_331),
            accepted_at: Some(ts(1_777_658_622)),
        }
    }

    fn fixture_activity() -> ActivitySnapshot {
        ActivitySnapshot {
            phase: ActivityPhase::CallingModel,
            label: "calling model".into(),
            started_at: "2026-04-25T12:00:00Z".into(),
            elapsed_ms: 4200,
            session_id: "repl-primary".into(),
            channel: ChannelKind::Repl,
            tool_name: None,
            tool_summary: None,
            skill_name: None,
            approval_id: None,
            last_progress_at: Some("2026-04-25T12:00:01Z".into()),
            stuck_hint: None,
            next_actions: vec!["wait for the model response".into()],
        }
    }

    #[test]
    fn proto_telemetry_snapshot_json_roundtrip() {
        let activity = fixture_activity();
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
            adapter: None,
            current_activity: Some(activity.clone()),
        };

        let raw = serde_json::to_string(&ServerMessage::SessionTelemetry(snapshot.clone()))
            .expect("telemetry should serialize");
        let decoded: ServerMessage =
            serde_json::from_str(&raw).expect("telemetry should deserialize");

        assert_eq!(decoded, ServerMessage::SessionTelemetry(snapshot));
    }

    #[test]
    fn proto_activity_snapshot_json_roundtrip() {
        let snapshot = fixture_activity();
        let raw = serde_json::to_string(&ServerMessage::ActivityUpdate(snapshot.clone()))
            .expect("activity should serialize");
        let decoded: ServerMessage =
            serde_json::from_str(&raw).expect("activity should deserialize");

        assert_eq!(decoded, ServerMessage::ActivityUpdate(snapshot));
    }

    #[test]
    fn proto_span_payload_json_roundtrip() {
        let mut attributes = BTreeMap::new();
        attributes.insert(
            "gen_ai.operation.name".into(),
            AttributeValue::String("chat".into()),
        );
        attributes.insert("gen_ai.usage.input_tokens".into(), AttributeValue::Int(42));

        let event = SpanEvent {
            timestamp: ts(1_774_044_801),
            name: "retry".into(),
            attributes: BTreeMap::from([(
                "reason".into(),
                AttributeValue::String("provider_timeout".into()),
            )]),
        };
        let span = Span {
            id: "1111111111111111".into(),
            parent_id: Some("2222222222222222".into()),
            session_id: "repl-primary".into(),
            trace_id: "33333333333333333333333333333333".into(),
            name: "chat".into(),
            kind: SpanKind::Client,
            started_at: ts(1_774_044_800),
            ended_at: Some(ts(1_774_044_802)),
            duration_ms: Some(2000),
            status: SpanStatus::Error {
                message: "provider_timeout".into(),
            },
            attributes,
            events: vec![event],
        };

        let raw =
            serde_json::to_string(&ServerMessage::TraceSpan(span.clone())).expect("serialize span");
        let decoded: ServerMessage = serde_json::from_str(&raw).expect("deserialize span");
        assert_eq!(decoded, ServerMessage::TraceSpan(span));
    }

    #[test]
    fn proto_trace_messages_json_roundtrip() {
        let subscribe = ClientMessage::TraceSubscribe {
            session_id: Some("session-a".into()),
        };
        let raw = serde_json::to_string(&subscribe).expect("subscribe should serialize");
        let decoded: ClientMessage =
            serde_json::from_str(&raw).expect("subscribe should deserialize");
        assert_eq!(decoded, subscribe);

        let show_span = ClientMessage::TraceShowSpan {
            session_id: None,
            span_id: "1111111111111111".into(),
        };
        let raw = serde_json::to_string(&show_span).expect("show-span should serialize");
        let decoded: ClientMessage =
            serde_json::from_str(&raw).expect("show-span should deserialize");
        assert_eq!(decoded, show_span);

        let summary = TraceSessionSummary {
            session_id: "session-a".into(),
            span_count: 3,
            root_span_count: 1,
            started_at: ts(1_774_044_800),
            last_touched_at: ts(1_774_044_810),
            total_duration_ms: 10_000,
            bytes: 2048,
            has_rotated_archives: true,
            truncated_count: 1,
        };
        let raw = serde_json::to_string(&ServerMessage::TraceSessions(vec![summary.clone()]))
            .expect("summary should serialize");
        let decoded: ServerMessage =
            serde_json::from_str(&raw).expect("summary should deserialize");
        assert_eq!(decoded, ServerMessage::TraceSessions(vec![summary]));
    }

    #[test]
    fn proto_adapter_manifest_json_roundtrip_and_schema_validation() {
        let manifest = fixture_adapter_manifest();
        manifest
            .validate_schema_version()
            .expect("fixture schema should be supported");

        let raw =
            serde_json::to_string(&ServerMessage::Adapter(manifest.clone())).expect("serialize");
        let decoded: ServerMessage = serde_json::from_str(&raw).expect("deserialize");
        assert_eq!(decoded, ServerMessage::Adapter(manifest));

        let future = AdapterManifest {
            schema_version: ADAPTER_MANIFEST_SCHEMA_VERSION + 1,
            ..fixture_adapter_manifest()
        };
        let error = future
            .validate_schema_version()
            .expect_err("future schema should be rejected");
        assert_eq!(error.schema_version, ADAPTER_MANIFEST_SCHEMA_VERSION + 1);
        assert_eq!(
            error.supported_schema_version,
            ADAPTER_MANIFEST_SCHEMA_VERSION
        );
    }

    #[test]
    fn proto_adapter_messages_json_roundtrip() {
        let manifest = fixture_adapter_manifest();
        let list = ServerMessage::Adapters(vec![manifest.clone()]);
        let raw = serde_json::to_string(&list).expect("adapter list should serialize");
        let decoded: ServerMessage =
            serde_json::from_str(&raw).expect("adapter list should deserialize");
        assert_eq!(decoded, list);

        let active = ActiveAdapter {
            adapter_id: manifest.adapter_id.clone(),
            base_model: manifest.base_model.clone(),
            activated_at: ts(1_777_659_000),
        };
        let status = ServerMessage::AdaptersStatus(AdaptersStatusPayload {
            active: Some(active.clone()),
            today_compute_wall_seconds: 932,
            compute_cap_wall_seconds: Some(7200),
            remaining_compute_wall_seconds: Some(6268),
            last_training_run_id: Some(manifest.training_run_id.clone()),
            last_training_status: Some(AdapterTrainingFinalStatus::Succeeded),
        });
        let raw = serde_json::to_string(&status).expect("status should serialize");
        let decoded: ServerMessage = serde_json::from_str(&raw).expect("status should deserialize");
        assert_eq!(decoded, status);

        let progress = ServerMessage::AdapterTrainingProgress(AdapterTrainingProgressPayload {
            run_id: manifest.training_run_id.clone(),
            phase: "trainer_invocation".into(),
            step: 4,
            total_steps: 200,
            elapsed_seconds: 30,
            eta_seconds: Some(1200),
            peak_resident_mb: 4096,
            last_loss: Some(1.2),
        });
        let raw = serde_json::to_string(&progress).expect("progress should serialize");
        let decoded: ServerMessage =
            serde_json::from_str(&raw).expect("progress should deserialize");
        assert_eq!(decoded, progress);

        let final_payload = ServerMessage::AdapterTrainingFinal(AdapterTrainingFinalPayload {
            run_id: manifest.training_run_id.clone(),
            status: AdapterTrainingFinalStatus::Succeeded,
            ended_at: ts(1_777_658_622),
            manifest_path: "/tmp/manifest.json".into(),
            approval_id: Some("aid-1".into()),
        });
        let raw = serde_json::to_string(&final_payload).expect("final should serialize");
        let decoded: ServerMessage = serde_json::from_str(&raw).expect("final should deserialize");
        assert_eq!(decoded, final_payload);

        let history = ServerMessage::AdaptersHistory(vec![AdaptersHistoryEntry {
            adapter_id: active.adapter_id,
            action: "activated".into(),
            at: active.activated_at,
            actor: Some("cli".into()),
            reason: None,
        }]);
        let raw = serde_json::to_string(&history).expect("history should serialize");
        let decoded: ServerMessage =
            serde_json::from_str(&raw).expect("history should deserialize");
        assert_eq!(decoded, history);
    }

    #[test]
    fn proto_adapter_client_messages_json_roundtrip() {
        let messages = vec![
            ClientMessage::AdaptersList,
            ClientMessage::AdaptersShow("adapter-1".into()),
            ClientMessage::AdaptersActivate(AdapterActivateRequest {
                adapter_id: "adapter-1".into(),
                override_reason: Some("reviewed eval output".into()),
            }),
            ClientMessage::AdaptersDeactivate,
            ClientMessage::AdaptersRemove(AdapterRemoveRequest {
                adapter_id: "adapter-1".into(),
                force: false,
            }),
            ClientMessage::AdaptersStatus,
            ClientMessage::AdaptersHistory(AdaptersHistoryRequest { limit: Some(10) }),
            ClientMessage::AdaptersTrainingStart(AdapterTrainingStartRequest {
                backend: Some("fake".into()),
                override_reason: None,
            }),
            ClientMessage::AdaptersTrainingCancel(AdapterTrainingCancelRequest {
                run_id: "run-1".into(),
            }),
            ClientMessage::AdaptersInstallExternal(AdapterInstallExternalRequest {
                path: "/tmp/adapter.gguf".into(),
            }),
        ];

        for message in messages {
            let raw = serde_json::to_string(&message).expect("client message should serialize");
            let decoded: ClientMessage =
                serde_json::from_str(&raw).expect("client message should deserialize");
            assert_eq!(decoded, message);
        }
    }

    #[test]
    fn proto_v2_v3_v4_v5_envelopes_decode_under_v6_reader() {
        let v2_status = r#"{"type":"status"}"#;
        assert_eq!(
            serde_json::from_str::<ClientMessage>(v2_status).expect("v2 status should decode"),
            ClientMessage::Status
        );

        let v3_activity = r#"{"type":"activity_snapshot"}"#;
        assert_eq!(
            serde_json::from_str::<ClientMessage>(v3_activity).expect("v3 activity should decode"),
            ClientMessage::ActivitySnapshot
        );

        let v4_trace = r#"{"type":"trace_list"}"#;
        assert_eq!(
            serde_json::from_str::<ClientMessage>(v4_trace).expect("v4 trace should decode"),
            ClientMessage::TraceList
        );

        let v5_adapter = r#"{"type":"adapters_status"}"#;
        assert_eq!(
            serde_json::from_str::<ClientMessage>(v5_adapter).expect("v5 adapter should decode"),
            ClientMessage::AdaptersStatus
        );
    }

    #[test]
    fn proto_v6_diagnosis_and_utility_messages_json_roundtrip() {
        let run = ClientMessage::DiagnoseRun(DiagnosisRunRequest {
            session_id: Some("repl-primary".into()),
            lookback_days: Some(7),
            remediation: Some(DiagnosisRemediationRequestPayload {
                kind: "skill".into(),
                reason: "operator requested".into(),
            }),
        });
        let raw = serde_json::to_string(&run).expect("diagnose run should serialize");
        let decoded: ClientMessage =
            serde_json::from_str(&raw).expect("diagnose run should deserialize");
        assert_eq!(decoded, run);

        let summary = DiagnosisReportSummaryPayload {
            schema_version: 1,
            diagnosis_id: "diag_20260426T000000Z_12345678".into(),
            session_id: "repl-primary".into(),
            created_at: ts(1_777_657_331),
            selected_session_ids: vec!["repl-primary".into()],
            classification: "tool_failed".into(),
            confidence: 0.9,
            rationale: "tool failed".into(),
            bounds: serde_json::json!({"max_sessions": 5}),
            truncation: serde_json::json!({"span_count": 0}),
            warnings: Vec::new(),
            span_count: 2,
            event_count: 1,
            report_path: "/tmp/report.md".into(),
            remediation: None,
        };
        let report = ServerMessage::DiagnosisReport(DiagnosisReportPayload {
            summary: summary.clone(),
            report_markdown: "# Diagnosis\n".into(),
        });
        let raw = serde_json::to_string(&report).expect("diagnosis report should serialize");
        let decoded: ServerMessage =
            serde_json::from_str(&raw).expect("diagnosis report should deserialize");
        assert_eq!(decoded, report);

        let utility = ServerMessage::Utility(UtilityCatalogEntryPayload {
            id: "rg".into(),
            name: "ripgrep".into(),
            description: "Fast search".into(),
            executable_candidates: vec!["rg".into()],
            installed_path: Some("/usr/bin/rg".into()),
            enabled: true,
            status: Some("ok".into()),
            path_canonical: Some("/usr/bin/rg".into()),
            version: Some("rg 14".into()),
            help_summary: Some("Fast search".into()),
            verified_at: Some("2026-04-26T00:00:00Z".into()),
            exec_note: Some("exec policy auto-allows this utility".into()),
        });
        let raw = serde_json::to_string(&utility).expect("utility should serialize");
        let decoded: ServerMessage =
            serde_json::from_str(&raw).expect("utility should deserialize");
        assert_eq!(decoded, utility);
    }

    #[test]
    fn proto_trace_identifier_helpers_accept_only_otlp_hex() {
        assert!(is_valid_otlp_trace_id("33333333333333333333333333333333"));
        assert!(is_valid_otlp_span_id("1111111111111111"));

        assert!(!is_valid_otlp_trace_id("00000000000000000000000000000000"));
        assert!(!is_valid_otlp_span_id("0000000000000000"));
        assert!(!is_valid_otlp_trace_id(
            "33333333-3333-3333-3333-333333333333"
        ));
        assert!(!is_valid_otlp_span_id("ABCDEFABCDEFABCD"));
        assert!(!is_valid_otlp_span_id("abc"));
    }

    #[test]
    fn proto_job_run_record_last_activity_roundtrip() {
        let activity = fixture_activity();
        let record = JobRunRecordPayload {
            run_id: "run-1".into(),
            job_name: "daily-brief".into(),
            session_id: "job-daily-brief".into(),
            started_at: "2026-04-20T00:00:00Z".into(),
            ended_at: "2026-04-20T00:01:00Z".into(),
            outcome: "failure".into(),
            cost_usd: 0.0,
            skills_attached: Vec::new(),
            stop_reason: Some("provider timeout".into()),
            last_activity: Some(activity.clone()),
        };
        let raw = serde_json::to_string(&record).expect("run record should serialize");
        let decoded: JobRunRecordPayload =
            serde_json::from_str(&raw).expect("run record should deserialize");
        assert_eq!(decoded.last_activity, Some(activity));
    }

    #[test]
    fn proto_activity_phase_roundtrip_tolerates_future_values() {
        let raw = r#""future_phase""#;
        let phase: ActivityPhase =
            serde_json::from_str(raw).expect("unknown phase should deserialize");
        assert_eq!(phase, ActivityPhase::Unknown);
    }

    #[test]
    fn proto_approval_context_variants_roundtrip() {
        let contexts = vec![
            ApprovalContext::ToolConfirm {
                tool_name: "process_exec".into(),
                cwd: Some("/tmp/project".into()),
                argument_summary: "cargo test".into(),
                why: "runs a local validation command".into(),
            },
            ApprovalContext::CostCapOverride {
                requested_increase: "$0.50".into(),
                current_daily_total: "$1.25".into(),
                configured_cap: "$1.00".into(),
                reason: "operator approved release smoke".into(),
            },
            ApprovalContext::JobApproval {
                job_kind: "scheduled".into(),
                schedule: "@daily at 07:00".into(),
                next_fire_time: "2026-04-26T14:00:00Z".into(),
                recurrence_summary: "daily".into(),
            },
            ApprovalContext::PatchApproval {
                branch: "allbert-rebuild-demo".into(),
                validation_status: "passed".into(),
                file_stats: "1 files".into(),
                artifact_path: "/tmp/patch.diff".into(),
                diff_preview: vec!["diff --git a/README.md b/README.md".into()],
            },
            ApprovalContext::MemoryPromotion {
                preview: "Primary database is Postgres.".into(),
                source: "session-a".into(),
                supersession_hint: "no supersession".into(),
            },
        ];

        for context in contexts {
            let raw = serde_json::to_string(&context).expect("context should serialize");
            let decoded: ApprovalContext =
                serde_json::from_str(&raw).expect("context should deserialize");
            assert_eq!(decoded, context);
        }
    }

    #[test]
    fn proto_approval_context_optional_payload_fields_roundtrip() {
        let context = ApprovalContext::ToolConfirm {
            tool_name: "process_exec".into(),
            cwd: Some("/tmp/project".into()),
            argument_summary: "cargo test".into(),
            why: "operator review".into(),
        };
        let confirm = ConfirmRequestPayload {
            request_id: 7,
            approval_id: Some("approval-7".into()),
            program: "process_exec".into(),
            args: vec!["cargo".into(), "test".into()],
            cwd: Some("/tmp/project".into()),
            rendered: "Run cargo test?".into(),
            expires_at: None,
            context: Some(context.clone()),
        };
        let raw = serde_json::to_string(&confirm).expect("confirm should serialize");
        let decoded: ConfirmRequestPayload =
            serde_json::from_str(&raw).expect("confirm should deserialize");
        assert_eq!(decoded.context, Some(context.clone()));

        let inbox = InboxApprovalPayload {
            id: "approval-7".into(),
            session_id: "session-a".into(),
            identity_id: Some("identity-a".into()),
            channel: ChannelKind::Repl,
            sender: "local".into(),
            agent: "allbert/root".into(),
            tool: "process_exec".into(),
            request_id: 7,
            kind: "tool-approval".into(),
            requested_at: "2026-04-20T00:00:00Z".into(),
            expires_at: "2026-04-20T01:00:00Z".into(),
            status: "pending".into(),
            resolved_at: None,
            resolver: None,
            reply: None,
            rendered: "Run cargo test?".into(),
            path: "/tmp/approval.md".into(),
            patch: None,
            context: Some(context.clone()),
        };
        let raw = serde_json::to_string(&inbox).expect("inbox should serialize");
        let decoded: InboxApprovalPayload =
            serde_json::from_str(&raw).expect("inbox should deserialize");
        assert_eq!(decoded.context, Some(context));
    }
}
