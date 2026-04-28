use std::collections::BTreeSet;
use std::fmt;
use std::path::{Component, Path};

use crate::{
    atomic_write, AllbertPaths, Config, MemoryRoutingMode, Provider, RagSourceKind, ReplUiMode,
    ScriptingEngineConfig, StatusLineItem, TuiSpinnerStyle,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SettingsGroup {
    Ui,
    Activity,
    Intent,
    Trace,
    SelfDiagnosis,
    LocalUtilities,
    Memory,
    Rag,
    Learning,
    Personalization,
    SelfImprovement,
    Providers,
}

impl SettingsGroup {
    pub const ALL: [Self; 12] = [
        Self::Ui,
        Self::Activity,
        Self::Intent,
        Self::Trace,
        Self::SelfDiagnosis,
        Self::LocalUtilities,
        Self::Memory,
        Self::Rag,
        Self::Learning,
        Self::Personalization,
        Self::SelfImprovement,
        Self::Providers,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::Ui => "ui",
            Self::Activity => "activity",
            Self::Intent => "intent",
            Self::Trace => "trace",
            Self::SelfDiagnosis => "self_diagnosis",
            Self::LocalUtilities => "local_utilities",
            Self::Memory => "memory",
            Self::Rag => "rag",
            Self::Learning => "learning",
            Self::Personalization => "personalization",
            Self::SelfImprovement => "self_improvement",
            Self::Providers => "providers",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Ui => "UI",
            Self::Activity => "Activity",
            Self::Intent => "Intent",
            Self::Trace => "Trace",
            Self::SelfDiagnosis => "Self-diagnosis",
            Self::LocalUtilities => "Local utilities",
            Self::Memory => "Memory",
            Self::Rag => "RAG",
            Self::Learning => "Learning",
            Self::Personalization => "Personalization",
            Self::SelfImprovement => "Self-improvement",
            Self::Providers => "Providers",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SettingValueType {
    Bool,
    UnsignedInteger { min: Option<u64>, max: Option<u64> },
    Float { min: Option<f64>, max: Option<f64> },
    String,
    OptionalString,
    Enum(&'static [&'static str]),
    StringList,
    Path(SettingPathPolicy),
    OptionalPath(SettingPathPolicy),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingPathPolicy {
    AllbertHomeRelative,
    FilesystemPath,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingRestartRequirement {
    Live,
    Restart,
}

impl SettingRestartRequirement {
    pub fn label(self) -> &'static str {
        match self {
            Self::Live => "live",
            Self::Restart => "restart",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingRedactionPolicy {
    Plain,
    Path,
    Redacted,
}

impl SettingRedactionPolicy {
    pub fn label(self) -> &'static str {
        match self {
            Self::Plain => "plain",
            Self::Path => "path",
            Self::Redacted => "redacted",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SettingDescriptor {
    pub key: &'static str,
    pub group: SettingsGroup,
    pub label: &'static str,
    pub description: &'static str,
    pub value_type: SettingValueType,
    pub default_value: &'static str,
    pub config_path: &'static str,
    pub restart: SettingRestartRequirement,
    pub safety_note: &'static str,
    pub redaction: SettingRedactionPolicy,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SettingView {
    pub key: String,
    pub group: SettingsGroup,
    pub group_label: &'static str,
    pub label: &'static str,
    pub description: &'static str,
    pub value_type: SettingValueType,
    pub default_value: String,
    pub current_value: String,
    pub config_path: String,
    pub restart: SettingRestartRequirement,
    pub safety_note: &'static str,
    pub redaction: SettingRedactionPolicy,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingValidationError {
    UnsupportedKey(String),
    InvalidValue { key: String, reason: String },
    SecretLikeKey(String),
    ArbitraryTomlEdit(String),
    PathEscape { key: String, value: String },
    ReservedRuntimePath { key: String, value: String },
}

impl fmt::Display for SettingValidationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedKey(key) => write!(f, "unsupported setting key `{key}`"),
            Self::InvalidValue { key, reason } => {
                write!(f, "invalid value for `{key}`: {reason}")
            }
            Self::SecretLikeKey(key) => {
                write!(f, "`{key}` looks like a secret and is not supported here")
            }
            Self::ArbitraryTomlEdit(key) => {
                write!(
                    f,
                    "`{key}` is not a setting key; arbitrary TOML edits are rejected"
                )
            }
            Self::PathEscape { key, value } => {
                write!(f, "`{key}` path `{value}` must stay inside ALLBERT_HOME")
            }
            Self::ReservedRuntimePath { key, value } => {
                write!(f, "`{key}` path `{value}` targets reserved runtime state")
            }
        }
    }
}

impl std::error::Error for SettingValidationError {}

#[derive(Debug)]
pub enum SettingPersistenceError {
    Validation(SettingValidationError),
    Read {
        path: String,
        source: std::io::Error,
    },
    Parse {
        path: String,
        message: String,
    },
    UnsafeEdit {
        key: String,
        hint: String,
    },
    RenderedConfigInvalid {
        key: String,
        message: String,
    },
    Write {
        path: String,
        source: std::io::Error,
    },
}

impl fmt::Display for SettingPersistenceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Validation(err) => write!(f, "{err}"),
            Self::Read { path, source } => write!(f, "read {path}: {source}"),
            Self::Parse { path, message } => write!(f, "parse {path}: {message}"),
            Self::UnsafeEdit { key, hint } => {
                write!(
                    f,
                    "cannot safely edit `{key}` while preserving TOML: {hint}"
                )
            }
            Self::RenderedConfigInvalid { key, message } => {
                write!(
                    f,
                    "not writing `{key}` because rendered config is invalid: {message}"
                )
            }
            Self::Write { path, source } => write!(f, "write {path}: {source}"),
        }
    }
}

impl std::error::Error for SettingPersistenceError {}

impl From<SettingValidationError> for SettingPersistenceError {
    fn from(value: SettingValidationError) -> Self {
        Self::Validation(value)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingMutation {
    pub key: String,
    pub config_path: String,
    pub previous_value: Option<String>,
    pub new_value: Option<String>,
    pub changed: bool,
}

pub fn settings_catalog() -> Vec<SettingDescriptor> {
    vec![
        descriptor(
            "repl.ui",
            SettingsGroup::Ui,
            "Interface mode",
            "Default interactive surface for the local terminal.",
            SettingValueType::Enum(&["tui", "classic"]),
            "tui",
            "repl.ui",
            SettingRestartRequirement::Restart,
            "Changing the default affects future REPL launches.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "repl.tui.spinner_style",
            SettingsGroup::Ui,
            "Spinner style",
            "Spinner style for in-flight TUI activity.",
            SettingValueType::Enum(&["braille", "dots", "bar", "off"]),
            "braille",
            "repl.tui.spinner_style",
            SettingRestartRequirement::Live,
            "Use off for reduced-motion/static activity display.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "repl.tui.tick_ms",
            SettingsGroup::Ui,
            "TUI tick interval",
            "Redraw tick interval for spinner and elapsed-time updates.",
            SettingValueType::UnsignedInteger {
                min: Some(40),
                max: Some(250),
            },
            "80",
            "repl.tui.tick_ms",
            SettingRestartRequirement::Live,
            "Values outside the supported range are rejected by the settings registry.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "repl.tui.status_line.enabled",
            SettingsGroup::Ui,
            "Status line",
            "Show or hide the TUI status line.",
            SettingValueType::Bool,
            "true",
            "repl.tui.status_line.enabled",
            SettingRestartRequirement::Live,
            "Disabling this hides compact runtime state but does not disable telemetry.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "repl.tui.status_line.items",
            SettingsGroup::Ui,
            "Status line items",
            "Ordered list of status-line items.",
            SettingValueType::StringList,
            "model,context,tokens,cost,memory,intent,skills,inbox,channel,trace",
            "repl.tui.status_line.items",
            SettingRestartRequirement::Live,
            "The list must not be empty when the status line is enabled.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "operator_ux.activity.stuck_notice_after_s",
            SettingsGroup::Activity,
            "Stuck notice threshold",
            "Seconds before quiet activity can show an advisory stuck hint.",
            SettingValueType::UnsignedInteger {
                min: Some(5),
                max: Some(600),
            },
            "30",
            "operator_ux.activity.stuck_notice_after_s",
            SettingRestartRequirement::Live,
            "Hints are advisory and never imply cancellation is available.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "operator_ux.activity.long_tool_notice_after_s",
            SettingsGroup::Activity,
            "Long tool threshold",
            "Seconds before a tool-like phase is called out as long-running.",
            SettingValueType::UnsignedInteger {
                min: Some(5),
                max: Some(600),
            },
            "20",
            "operator_ux.activity.long_tool_notice_after_s",
            SettingRestartRequirement::Live,
            "Used only for operator hints; it does not cancel work.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "operator_ux.activity.show_activity_breadcrumbs",
            SettingsGroup::Activity,
            "Activity breadcrumbs",
            "Show compact activity breadcrumbs in surfaces that support them.",
            SettingValueType::Bool,
            "true",
            "operator_ux.activity.show_activity_breadcrumbs",
            SettingRestartRequirement::Live,
            "Disabling display does not disable daemon activity tracking.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "intent.tool_call_retry_enabled",
            SettingsGroup::Intent,
            "Tool-call retry",
            "Retry once with corrective tool-call guidance when a model emits malformed tool XML.",
            SettingValueType::Bool,
            "true",
            "intent.tool_call_retry_enabled",
            SettingRestartRequirement::Live,
            "Disabling retry surfaces parser failures directly instead of spending one more provider call.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "trace.enabled",
            SettingsGroup::Trace,
            "Trace persistence",
            "Persist durable session spans for after-the-fact replay.",
            SettingValueType::Bool,
            "true",
            "trace.enabled",
            SettingRestartRequirement::Live,
            "Disabling this stops trace persistence; live activity surfaces continue working.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "trace.capture_messages",
            SettingsGroup::Trace,
            "Capture message text",
            "Capture full prompts, responses, tool args, and tool results before redaction.",
            SettingValueType::Bool,
            "true",
            "trace.capture_messages",
            SettingRestartRequirement::Restart,
            "When false, capture policies for tool args, tool results, and provider payloads are coerced to summary for that load.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "trace.session_disk_cap_mb",
            SettingsGroup::Trace,
            "Per-session trace cap",
            "Per-session trace artifact cap in MiB.",
            SettingValueType::UnsignedInteger {
                min: Some(5),
                max: Some(500),
            },
            "50",
            "trace.session_disk_cap_mb",
            SettingRestartRequirement::Restart,
            "Old trace archives may be evicted past this cap; other session artifacts are not removed.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "trace.total_disk_cap_mb",
            SettingsGroup::Trace,
            "Total trace cap",
            "Total trace artifact cap across sessions in MiB.",
            SettingValueType::UnsignedInteger {
                min: Some(100),
                max: Some(51200),
            },
            "2048",
            "trace.total_disk_cap_mb",
            SettingRestartRequirement::Restart,
            "Trace GC removes only trace artifacts, never unrelated session files.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "trace.retention_days",
            SettingsGroup::Trace,
            "Trace retention",
            "Days to retain trace artifacts before trace GC may remove them.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(365),
            },
            "30",
            "trace.retention_days",
            SettingRestartRequirement::Restart,
            "Retention applies to trace artifacts only.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "trace.otel_export_dir",
            SettingsGroup::Trace,
            "OTLP export directory",
            "Profile-relative directory for explicit OTLP-JSON exports.",
            SettingValueType::OptionalPath(SettingPathPolicy::AllbertHomeRelative),
            "",
            "trace.otel_export_dir",
            SettingRestartRequirement::Live,
            "Exports must stay inside ALLBERT_HOME; network exporters are not supported.",
            SettingRedactionPolicy::Path,
        ),
        descriptor(
            "trace.otel_service_name",
            SettingsGroup::Trace,
            "OTLP service name",
            "Service name written into file-based OTLP-JSON exports.",
            SettingValueType::String,
            "allbert",
            "trace.otel_service_name",
            SettingRestartRequirement::Live,
            "Changing this affects future exports only.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "trace.redaction.secrets",
            SettingsGroup::Trace,
            "Secret redaction",
            "Secret redaction posture for trace writes and exports.",
            SettingValueType::Enum(&["always"]),
            "always",
            "trace.redaction.secrets",
            SettingRestartRequirement::Restart,
            "Read-only: secrets are always redacted and this setting cannot be weakened.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "trace.redaction.tool_args",
            SettingsGroup::Trace,
            "Tool argument capture",
            "Capture policy for tool argument attributes.",
            SettingValueType::Enum(&["capture", "summary", "drop"]),
            "capture",
            "trace.redaction.tool_args",
            SettingRestartRequirement::Restart,
            "Use summary or drop when tool arguments may contain sensitive data.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "trace.redaction.tool_results",
            SettingsGroup::Trace,
            "Tool result capture",
            "Capture policy for tool result attributes.",
            SettingValueType::Enum(&["capture", "summary", "drop"]),
            "capture",
            "trace.redaction.tool_results",
            SettingRestartRequirement::Restart,
            "Use summary or drop when tool results may contain sensitive data.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "trace.redaction.provider_payloads",
            SettingsGroup::Trace,
            "Provider payload capture",
            "Capture policy for raw prompt/response provider payload attributes.",
            SettingValueType::Enum(&["capture", "summary", "drop"]),
            "capture",
            "trace.redaction.provider_payloads",
            SettingRestartRequirement::Restart,
            "Use summary or drop to avoid storing raw model input or output text.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_diagnosis.enabled",
            SettingsGroup::SelfDiagnosis,
            "Self-diagnosis",
            "Allow report-only diagnosis over bounded local trace artifacts.",
            SettingValueType::Bool,
            "true",
            "self_diagnosis.enabled",
            SettingRestartRequirement::Live,
            "Disabling this makes the self_diagnose tool and diagnose commands refuse work.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_diagnosis.lookback_days",
            SettingsGroup::SelfDiagnosis,
            "Trace lookback",
            "Maximum age of trace sessions considered by default diagnosis.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(90),
            },
            "7",
            "self_diagnosis.lookback_days",
            SettingRestartRequirement::Live,
            "An explicit session still limits diagnosis to that session.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_diagnosis.max_sessions",
            SettingsGroup::SelfDiagnosis,
            "Session cap",
            "Maximum number of recent sessions included in one diagnostic bundle.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(50),
            },
            "5",
            "self_diagnosis.max_sessions",
            SettingRestartRequirement::Live,
            "The active session is preferred, then recent sessions fill the remaining cap.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_diagnosis.max_spans",
            SettingsGroup::SelfDiagnosis,
            "Span cap",
            "Maximum number of trace spans included in one diagnostic bundle.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(10_000),
            },
            "1000",
            "self_diagnosis.max_spans",
            SettingRestartRequirement::Live,
            "Additional spans are counted as truncation, not read unbounded.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_diagnosis.max_events",
            SettingsGroup::SelfDiagnosis,
            "Event cap",
            "Maximum number of trace events included in one diagnostic bundle.",
            SettingValueType::UnsignedInteger {
                min: Some(0),
                max: Some(50_000),
            },
            "2000",
            "self_diagnosis.max_events",
            SettingRestartRequirement::Live,
            "Use 0 to include span summaries without per-event details.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_diagnosis.max_text_snippet_bytes",
            SettingsGroup::SelfDiagnosis,
            "Text snippet cap",
            "Maximum bytes retained for any redacted text field in a diagnostic bundle.",
            SettingValueType::UnsignedInteger {
                min: Some(1_024),
                max: Some(262_144),
            },
            "32768",
            "self_diagnosis.max_text_snippet_bytes",
            SettingRestartRequirement::Live,
            "Long text fields are truncated with an explicit marker.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_diagnosis.max_report_bytes",
            SettingsGroup::SelfDiagnosis,
            "Report cap",
            "Maximum bytes for a rendered diagnosis report artifact.",
            SettingValueType::UnsignedInteger {
                min: Some(8_192),
                max: Some(1_048_576),
            },
            "262144",
            "self_diagnosis.max_report_bytes",
            SettingRestartRequirement::Live,
            "M2 report rendering must truncate rather than exceed this cap.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_diagnosis.allow_remediation",
            SettingsGroup::SelfDiagnosis,
            "Allow remediation",
            "Opt-in gate for explicit diagnosis remediation requests.",
            SettingValueType::Bool,
            "false",
            "self_diagnosis.allow_remediation",
            SettingRestartRequirement::Live,
            "Report-only diagnosis remains available while remediation is disabled.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_diagnosis.remediation_provider_max_tokens",
            SettingsGroup::SelfDiagnosis,
            "Remediation max tokens",
            "Maximum output tokens for self-diagnosis remediation candidate generation.",
            SettingValueType::UnsignedInteger {
                min: Some(256),
                max: Some(16_384),
            },
            "4096",
            "self_diagnosis.remediation_provider_max_tokens",
            SettingRestartRequirement::Live,
            "The daily cost cap still gates remediation calls before this token cap is used.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "local_utilities.enabled",
            SettingsGroup::LocalUtilities,
            "Local utilities",
            "Allow operator-enabled local utilities to be used by v0.14 utility surfaces.",
            SettingValueType::Bool,
            "true",
            "local_utilities.enabled",
            SettingRestartRequirement::Live,
            "Disabling this leaves the host-specific manifest in place but refuses utility mutations and unix_pipe use.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "local_utilities.unix_pipe_max_stages",
            SettingsGroup::LocalUtilities,
            "Unix pipe stages",
            "Maximum number of direct-spawn utility stages in one unix_pipe run.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(10),
            },
            "5",
            "local_utilities.unix_pipe_max_stages",
            SettingRestartRequirement::Live,
            "Lower this if you want fewer composed processes per tool call.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "local_utilities.unix_pipe_timeout_s",
            SettingsGroup::LocalUtilities,
            "Unix pipe timeout",
            "Maximum wall-clock seconds for one unix_pipe run.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(300),
            },
            "30",
            "local_utilities.unix_pipe_timeout_s",
            SettingRestartRequirement::Live,
            "Timeout kills the whole pipeline rather than leaving child processes running.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "local_utilities.unix_pipe_max_stdin_bytes",
            SettingsGroup::LocalUtilities,
            "Unix pipe stdin cap",
            "Maximum bytes accepted as stdin for one unix_pipe run.",
            SettingValueType::UnsignedInteger {
                min: Some(1_024),
                max: Some(16_777_216),
            },
            "1048576",
            "local_utilities.unix_pipe_max_stdin_bytes",
            SettingRestartRequirement::Live,
            "Large inputs should travel through files under trusted roots instead of tool arguments.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "local_utilities.unix_pipe_max_stdout_bytes",
            SettingsGroup::LocalUtilities,
            "Unix pipe stdout cap",
            "Maximum bytes retained from final unix_pipe stdout.",
            SettingValueType::UnsignedInteger {
                min: Some(1_024),
                max: Some(16_777_216),
            },
            "1048576",
            "local_utilities.unix_pipe_max_stdout_bytes",
            SettingRestartRequirement::Live,
            "Output beyond this cap is truncated with an explicit marker.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "local_utilities.unix_pipe_max_stderr_bytes",
            SettingsGroup::LocalUtilities,
            "Unix pipe stderr cap",
            "Maximum bytes retained from each unix_pipe stage stderr.",
            SettingValueType::UnsignedInteger {
                min: Some(1_024),
                max: Some(16_777_216),
            },
            "262144",
            "local_utilities.unix_pipe_max_stderr_bytes",
            SettingRestartRequirement::Live,
            "Stderr summaries stay bounded for trace and report safety.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "local_utilities.unix_pipe_max_args_per_stage",
            SettingsGroup::LocalUtilities,
            "Unix pipe args per stage",
            "Maximum argv argument count for a single unix_pipe stage.",
            SettingValueType::UnsignedInteger {
                min: Some(0),
                max: Some(256),
            },
            "64",
            "local_utilities.unix_pipe_max_args_per_stage",
            SettingRestartRequirement::Live,
            "Use stdin or trusted-root files for larger inputs.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "local_utilities.unix_pipe_max_arg_bytes",
            SettingsGroup::LocalUtilities,
            "Unix pipe arg cap",
            "Maximum bytes for one unix_pipe argv argument.",
            SettingValueType::UnsignedInteger {
                min: Some(64),
                max: Some(65_536),
            },
            "4096",
            "local_utilities.unix_pipe_max_arg_bytes",
            SettingRestartRequirement::Live,
            "Arguments remain bounded because they are captured in policy and trace metadata.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "local_utilities.unix_pipe_max_argv_bytes",
            SettingsGroup::LocalUtilities,
            "Unix pipe argv cap",
            "Maximum total argv bytes for one unix_pipe stage.",
            SettingValueType::UnsignedInteger {
                min: Some(1_024),
                max: Some(262_144),
            },
            "32768",
            "local_utilities.unix_pipe_max_argv_bytes",
            SettingRestartRequirement::Live,
            "The total cap must stay at least as large as the per-argument cap.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "memory.prefetch_enabled",
            SettingsGroup::Memory,
            "Memory prefetch",
            "Enable curated-memory prefetch during prompt assembly.",
            SettingValueType::Bool,
            "true",
            "memory.prefetch_enabled",
            SettingRestartRequirement::Live,
            "Does not promote staged memory.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "memory.routing.mode",
            SettingsGroup::Memory,
            "Memory routing mode",
            "How memory-curation skills become eligible.",
            SettingValueType::Enum(&["always_eligible"]),
            "always_eligible",
            "memory.routing.mode",
            SettingRestartRequirement::Live,
            "Only supported routing modes are accepted.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "memory.episodes.prefetch_enabled",
            SettingsGroup::Memory,
            "Episode prefetch",
            "Allow prior-session episode summaries in prefetch.",
            SettingValueType::Bool,
            "false",
            "memory.episodes.prefetch_enabled",
            SettingRestartRequirement::Live,
            "Episodes are working-history recall, not durable approved memory.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "memory.semantic.enabled",
            SettingsGroup::Memory,
            "Semantic memory",
            "Enable the optional derived semantic retrieval layer.",
            SettingValueType::Bool,
            "false",
            "memory.semantic.enabled",
            SettingRestartRequirement::Restart,
            "BM25/Tantivy remains the default retrieval path.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "memory.trash_retention_days",
            SettingsGroup::Memory,
            "Memory trash retention",
            "Days to keep soft-deleted durable memory.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(365),
            },
            "30",
            "memory.trash_retention_days",
            SettingRestartRequirement::Live,
            "GC removes only eligible trash entries.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "memory.rejected_retention_days",
            SettingsGroup::Memory,
            "Rejected staged-memory retention",
            "Days to keep soft-rejected staged memory.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(365),
            },
            "30",
            "memory.rejected_retention_days",
            SettingRestartRequirement::Live,
            "Reconsider can only restore non-conflicting entries.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.enabled",
            SettingsGroup::Rag,
            "RAG retrieval",
            "Enable prompt-time RAG retrieval and operator RAG commands.",
            SettingValueType::Bool,
            "true",
            "rag.enabled",
            SettingRestartRequirement::Live,
            "Disabling RAG leaves memory synopsis and explicit memory search available.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.mode",
            SettingsGroup::Rag,
            "RAG retrieval mode",
            "Default retrieval mode when both lexical and vector indexes are available.",
            SettingValueType::Enum(&["hybrid", "vector", "lexical"]),
            "hybrid",
            "rag.mode",
            SettingRestartRequirement::Live,
            "Vector mode degrades to lexical when vectors are disabled or unavailable.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.max_chunks_per_turn",
            SettingsGroup::Rag,
            "RAG chunk cap",
            "Maximum RAG chunks injected into one prompt.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(32),
            },
            "6",
            "rag.max_chunks_per_turn",
            SettingRestartRequirement::Live,
            "Prompt context stays bounded even when search returns many matches.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.max_chunk_bytes",
            SettingsGroup::Rag,
            "RAG chunk bytes",
            "Maximum bytes retained for one retrieved RAG chunk.",
            SettingValueType::UnsignedInteger {
                min: Some(256),
                max: Some(8192),
            },
            "1200",
            "rag.max_chunk_bytes",
            SettingRestartRequirement::Live,
            "Larger source passages are truncated with provenance preserved.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.max_prompt_bytes",
            SettingsGroup::Rag,
            "RAG prompt bytes",
            "Maximum total RAG evidence bytes injected into one prompt.",
            SettingValueType::UnsignedInteger {
                min: Some(1024),
                max: Some(65536),
            },
            "7200",
            "rag.max_prompt_bytes",
            SettingRestartRequirement::Live,
            "RAG evidence is a bounded prompt section, not an unbounded transcript dump.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.refresh_after_external_evidence",
            SettingsGroup::Rag,
            "RAG refresh after tools",
            "Allow one capped RAG refresh after file/process/search-like tool evidence.",
            SettingValueType::Bool,
            "true",
            "rag.refresh_after_external_evidence",
            SettingRestartRequirement::Live,
            "Refreshes are capped and never authorize actions.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.sources",
            SettingsGroup::Rag,
            "RAG prompt sources",
            "Source kinds eligible for ordinary prompt-time RAG retrieval.",
            SettingValueType::StringList,
            "operator_docs,command_catalog,settings_catalog,skills_metadata,durable_memory,fact_memory,episode_recall,session_summary",
            "rag.sources",
            SettingRestartRequirement::Live,
            "Review-only staged content must not be enabled as an ordinary prompt source.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.include_inactive_skill_bodies",
            SettingsGroup::Rag,
            "Inactive skill bodies",
            "Allow indexing inactive skill bodies instead of metadata only.",
            SettingValueType::Bool,
            "false",
            "rag.include_inactive_skill_bodies",
            SettingRestartRequirement::Live,
            "The default indexes skill metadata without injecting inactive skill bodies.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.max_files_per_collection",
            SettingsGroup::Rag,
            "RAG collection file cap",
            "Maximum local files ingested for one user RAG collection.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(100_000),
            },
            "500",
            "rag.ingest.max_files_per_collection",
            SettingRestartRequirement::Live,
            "Caps user corpus ingestion before it can grow unbounded.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.max_file_bytes",
            SettingsGroup::Rag,
            "RAG collection file bytes",
            "Maximum bytes read from one local file source.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(104_857_600),
            },
            "1048576",
            "rag.ingest.max_file_bytes",
            SettingRestartRequirement::Live,
            "Oversized files are recorded as skipped/error sources.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.max_collection_bytes",
            SettingsGroup::Rag,
            "RAG collection byte cap",
            "Maximum total local bytes read for one collection ingest.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(10_737_418_240),
            },
            "52428800",
            "rag.ingest.max_collection_bytes",
            SettingRestartRequirement::Live,
            "Caps protect the daemon from unbounded user corpora.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.allowed_url_schemes",
            SettingsGroup::Rag,
            "RAG URL schemes",
            "URL schemes allowed for user RAG web ingestion.",
            SettingValueType::StringList,
            "https",
            "rag.ingest.allowed_url_schemes",
            SettingRestartRequirement::Live,
            "HTTP also requires an explicit collection fetch policy opt-in.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.allow_insecure_http",
            SettingsGroup::Rag,
            "RAG insecure HTTP",
            "Allow collection fetch policies to ingest http:// sources.",
            SettingValueType::Bool,
            "false",
            "rag.ingest.allow_insecure_http",
            SettingRestartRequirement::Live,
            "Leave disabled unless a trusted local corpus requires HTTP.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.url_depth",
            SettingsGroup::Rag,
            "RAG URL crawl depth",
            "Maximum same-origin crawl depth for web collection ingestion.",
            SettingValueType::UnsignedInteger {
                min: Some(0),
                max: Some(3),
            },
            "0",
            "rag.ingest.url_depth",
            SettingRestartRequirement::Live,
            "v0.15 defaults to exact URL fetches.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.url_max_pages",
            SettingsGroup::Rag,
            "RAG URL page cap",
            "Maximum pages fetched for one URL collection source.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(1000),
            },
            "1",
            "rag.ingest.url_max_pages",
            SettingRestartRequirement::Live,
            "Caps apply before content is indexed.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.url_max_bytes",
            SettingsGroup::Rag,
            "RAG URL byte cap",
            "Maximum response bytes read from one URL.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(104_857_600),
            },
            "2097152",
            "rag.ingest.url_max_bytes",
            SettingRestartRequirement::Live,
            "Oversized responses are skipped instead of partially indexed.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.url_max_redirects",
            SettingsGroup::Rag,
            "RAG URL redirects",
            "Maximum redirects followed for one URL fetch.",
            SettingValueType::UnsignedInteger {
                min: Some(0),
                max: Some(20),
            },
            "5",
            "rag.ingest.url_max_redirects",
            SettingRestartRequirement::Live,
            "Each redirect target is revalidated before fetch.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.fetch_timeout_s",
            SettingsGroup::Rag,
            "RAG fetch timeout",
            "Seconds allowed for one web fetch.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(600),
            },
            "20",
            "rag.ingest.fetch_timeout_s",
            SettingRestartRequirement::Live,
            "Timed-out URL sources are recorded as errors.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.respect_robots_txt",
            SettingsGroup::Rag,
            "RAG robots.txt",
            "Respect robots.txt when ingesting web URL collections.",
            SettingValueType::Bool,
            "true",
            "rag.ingest.respect_robots_txt",
            SettingRestartRequirement::Live,
            "Collection policies can only be less permissive unless config allows otherwise.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.allowed_content_types",
            SettingsGroup::Rag,
            "RAG content types",
            "HTTP content types allowed for web RAG ingestion.",
            SettingValueType::StringList,
            "text/plain,text/markdown,text/html,application/xhtml+xml",
            "rag.ingest.allowed_content_types",
            SettingRestartRequirement::Live,
            "Binary or unknown web responses are skipped.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.ingest.user_agent",
            SettingsGroup::Rag,
            "RAG fetch user agent",
            "User-Agent string sent for web RAG ingestion.",
            SettingValueType::String,
            "AllbertRagBot/0.15",
            "rag.ingest.user_agent",
            SettingRestartRequirement::Live,
            "Use an identifiable value for web-origin collection fetches.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.enabled",
            SettingsGroup::Rag,
            "RAG vectors",
            "Enable local vector indexing and vector query retrieval.",
            SettingValueType::Bool,
            "false",
            "rag.vector.enabled",
            SettingRestartRequirement::Restart,
            "Requires a local embedding provider and a vector rebuild.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.provider",
            SettingsGroup::Rag,
            "RAG vector provider",
            "Embedding provider used for RAG vector indexing and queries.",
            SettingValueType::Enum(&["ollama", "fake"]),
            "ollama",
            "rag.vector.provider",
            SettingRestartRequirement::Restart,
            "Fake embeddings are for deterministic tests only.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.model",
            SettingsGroup::Rag,
            "RAG embedding model",
            "Embedding model identifier used by the vector provider.",
            SettingValueType::String,
            "embeddinggemma",
            "rag.vector.model",
            SettingRestartRequirement::Restart,
            "Changing the model invalidates stored vectors and requires rebuild.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.base_url",
            SettingsGroup::Rag,
            "RAG vector base URL",
            "Base URL for the local embedding provider.",
            SettingValueType::String,
            "http://127.0.0.1:11434",
            "rag.vector.base_url",
            SettingRestartRequirement::Restart,
            "Use a local endpoint unless a future hosted-provider ADR permits otherwise.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.distance",
            SettingsGroup::Rag,
            "RAG vector distance",
            "Distance metric used by the vector backend.",
            SettingValueType::Enum(&["cosine"]),
            "cosine",
            "rag.vector.distance",
            SettingRestartRequirement::Restart,
            "The first implementation supports cosine only.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.batch_size",
            SettingsGroup::Rag,
            "RAG vector batch size",
            "Maximum source chunks sent in one embedding batch.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(256),
            },
            "16",
            "rag.vector.batch_size",
            SettingRestartRequirement::Live,
            "Lower this on machines with small local-model memory budgets.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.query_timeout_s",
            SettingsGroup::Rag,
            "RAG query timeout",
            "Seconds allowed for one query embedding request.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(300),
            },
            "15",
            "rag.vector.query_timeout_s",
            SettingRestartRequirement::Live,
            "Timeout falls back to lexical search when fallback is enabled.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.index_timeout_s",
            SettingsGroup::Rag,
            "RAG index timeout",
            "Seconds allowed for one vector indexing phase.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(86400),
            },
            "900",
            "rag.vector.index_timeout_s",
            SettingRestartRequirement::Live,
            "Long vector indexing work remains daemon-visible and cancellable.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.max_query_bytes",
            SettingsGroup::Rag,
            "RAG query byte cap",
            "Maximum bytes accepted for a vector query embedding.",
            SettingValueType::UnsignedInteger {
                min: Some(128),
                max: Some(65536),
            },
            "4096",
            "rag.vector.max_query_bytes",
            SettingRestartRequirement::Live,
            "Query embeddings stay bounded before leaving the process.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.max_concurrent_queries",
            SettingsGroup::Rag,
            "RAG query concurrency",
            "Maximum concurrent query embedding requests.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(16),
            },
            "2",
            "rag.vector.max_concurrent_queries",
            SettingRestartRequirement::Live,
            "Protects local Ollama from prompt-time query storms.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.retry_attempts",
            SettingsGroup::Rag,
            "RAG vector retries",
            "Retry attempts for transient embedding failures.",
            SettingValueType::UnsignedInteger {
                min: Some(0),
                max: Some(10),
            },
            "2",
            "rag.vector.retry_attempts",
            SettingRestartRequirement::Live,
            "Exhausted retries degrade vector posture rather than failing lexical search.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.fallback_to_lexical",
            SettingsGroup::Rag,
            "RAG lexical fallback",
            "Fall back to lexical retrieval when vector search is unavailable.",
            SettingValueType::Bool,
            "true",
            "rag.vector.fallback_to_lexical",
            SettingRestartRequirement::Live,
            "Disabling fallback can make vector-only searches fail closed.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.vector.fusion_vector_weight",
            SettingsGroup::Rag,
            "RAG vector fusion weight",
            "Hybrid retrieval weight assigned to vector results.",
            SettingValueType::Float {
                min: Some(0.0),
                max: Some(1.0),
            },
            "0.7",
            "rag.vector.fusion_vector_weight",
            SettingRestartRequirement::Live,
            "Lexical search remains part of hybrid retrieval unless this is set to 1.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.index.auto_maintain",
            SettingsGroup::Rag,
            "RAG auto-maintain",
            "Allow daemon-owned RAG maintenance service work.",
            SettingValueType::Bool,
            "true",
            "rag.index.auto_maintain",
            SettingRestartRequirement::Live,
            "Maintenance is deterministic service work, not a prompt-authored job.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.index.schedule_enabled",
            SettingsGroup::Rag,
            "RAG schedule",
            "Enable scheduled stale-only RAG maintenance.",
            SettingValueType::Bool,
            "false",
            "rag.index.schedule_enabled",
            SettingRestartRequirement::Live,
            "Manual status/search/rebuild commands remain available while disabled.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.index.schedule",
            SettingsGroup::Rag,
            "RAG maintenance schedule",
            "Bounded schedule expression for stale-only RAG maintenance.",
            SettingValueType::String,
            "@daily at 03:30",
            "rag.index.schedule",
            SettingRestartRequirement::Live,
            "Missed scheduled runs coalesce instead of replaying a catch-up storm.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.index.stale_only",
            SettingsGroup::Rag,
            "RAG stale-only rebuild",
            "Default scheduled rebuild posture.",
            SettingValueType::Bool,
            "true",
            "rag.index.stale_only",
            SettingRestartRequirement::Live,
            "Scheduled maintenance should not rebuild unchanged sources.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.index.run_on_startup_if_missing",
            SettingsGroup::Rag,
            "RAG startup rebuild",
            "Rebuild lexical RAG at startup when the derived SQLite file is missing.",
            SettingValueType::Bool,
            "true",
            "rag.index.run_on_startup_if_missing",
            SettingRestartRequirement::Live,
            "Startup rebuild is lexical-first and vector work is a second phase.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.index.coalesce_missed_runs",
            SettingsGroup::Rag,
            "RAG missed-run coalescing",
            "Coalesce missed scheduled runs into one stale-only run.",
            SettingValueType::Bool,
            "true",
            "rag.index.coalesce_missed_runs",
            SettingRestartRequirement::Live,
            "Prevents maintenance storms after sleep or shutdown.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.index.shutdown_grace_s",
            SettingsGroup::Rag,
            "RAG shutdown grace",
            "Seconds allowed for graceful scheduled rebuild cancellation.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(600),
            },
            "30",
            "rag.index.shutdown_grace_s",
            SettingRestartRequirement::Live,
            "Manual cancellation is separate and explicit.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.index.max_run_seconds",
            SettingsGroup::Rag,
            "RAG run time cap",
            "Maximum wall-clock seconds for one maintenance run.",
            SettingValueType::UnsignedInteger {
                min: Some(60),
                max: Some(86400),
            },
            "1800",
            "rag.index.max_run_seconds",
            SettingRestartRequirement::Live,
            "Long-running rebuilds fail visibly rather than running forever.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "rag.index.max_chunks_per_run",
            SettingsGroup::Rag,
            "RAG run chunk cap",
            "Maximum chunks processed in one maintenance run.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(1_000_000),
            },
            "5000",
            "rag.index.max_chunks_per_run",
            SettingRestartRequirement::Live,
            "Caps protect daemon maintenance from unbounded source growth.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.enabled",
            SettingsGroup::Learning,
            "Learning jobs",
            "Master switch for optional learning-job surfaces.",
            SettingValueType::Bool,
            "false",
            "learning.enabled",
            SettingRestartRequirement::Live,
            "Learning jobs remain review-first.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.compute_cap_wall_seconds",
            SettingsGroup::Personalization,
            "Daily adapter compute cap",
            "Daily wall-clock cap for local adapter training; 0 disables the cap.",
            SettingValueType::UnsignedInteger {
                min: Some(0),
                max: Some(86_400),
            },
            "7200",
            "learning.compute_cap_wall_seconds",
            SettingRestartRequirement::Live,
            "Only local trainer wall-clock time is counted; hosted-provider spend caps are separate.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.enabled",
            SettingsGroup::Personalization,
            "Adapter training",
            "Enable local review-first personality adapter training.",
            SettingValueType::Bool,
            "false",
            "learning.adapter_training.enabled",
            SettingRestartRequirement::Live,
            "Training still requires an allowed backend and exec-policy allowlist entry.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.allowed_backends",
            SettingsGroup::Personalization,
            "Allowed adapter backends",
            "Comma-separated trainer backend identifiers allowed for local adapter training.",
            SettingValueType::StringList,
            "",
            "learning.adapter_training.allowed_backends",
            SettingRestartRequirement::Live,
            "Allowed values are mlx-lm-lora, llama-cpp-finetune, and fake.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.default_backend",
            SettingsGroup::Personalization,
            "Default adapter backend",
            "Trainer backend used when adapter training starts without an explicit backend.",
            SettingValueType::OptionalString,
            "",
            "learning.adapter_training.default_backend",
            SettingRestartRequirement::Live,
            "Required only when adapter training is enabled and must also appear in allowed_backends.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.schedule",
            SettingsGroup::Personalization,
            "Adapter training schedule",
            "Optional bounded schedule expression for future scheduled adapter training.",
            SettingValueType::OptionalString,
            "",
            "learning.adapter_training.schedule",
            SettingRestartRequirement::Live,
            "Empty disables scheduled adapter training.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.include_tiers",
            SettingsGroup::Personalization,
            "Adapter corpus memory tiers",
            "Comma-separated memory tiers included in adapter-training corpus assembly.",
            SettingValueType::StringList,
            "durable,fact",
            "learning.adapter_training.include_tiers",
            SettingRestartRequirement::Live,
            "Allowed values are durable, fact, and episode.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.include_episodes",
            SettingsGroup::Personalization,
            "Adapter corpus episodes",
            "Allow bounded episode summaries in adapter-training corpus input.",
            SettingValueType::Bool,
            "true",
            "learning.adapter_training.include_episodes",
            SettingRestartRequirement::Live,
            "Episodes remain bounded working-history input.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.episode_lookback_days",
            SettingsGroup::Personalization,
            "Adapter episode lookback",
            "Days of session history eligible for adapter corpus episode summaries.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(365),
            },
            "30",
            "learning.adapter_training.episode_lookback_days",
            SettingRestartRequirement::Live,
            "Corpus assembly remains bounded by max_episode_summaries and max_input_bytes.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.max_episode_summaries",
            SettingsGroup::Personalization,
            "Adapter max episodes",
            "Maximum episode summaries included in an adapter corpus.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(1024),
            },
            "16",
            "learning.adapter_training.max_episode_summaries",
            SettingRestartRequirement::Live,
            "Higher values can increase local training time and corpus size.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.max_input_bytes",
            SettingsGroup::Personalization,
            "Adapter max input bytes",
            "Maximum bytes of local corpus input for one adapter training run.",
            SettingValueType::UnsignedInteger {
                min: Some(1024),
                max: Some(10 * 1024 * 1024),
            },
            "262144",
            "learning.adapter_training.max_input_bytes",
            SettingRestartRequirement::Live,
            "Corpus material is assembled locally and remains review-first.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.max_output_artifact_bytes",
            SettingsGroup::Personalization,
            "Adapter max artifact bytes",
            "Maximum bytes a trainer may write for one adapter run.",
            SettingValueType::UnsignedInteger {
                min: Some(1024),
                max: Some(100 * 1024 * 1024 * 1024),
            },
            "5368709120",
            "learning.adapter_training.max_output_artifact_bytes",
            SettingRestartRequirement::Live,
            "Prevents runaway local artifacts from filling the profile.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.capture_traces",
            SettingsGroup::Personalization,
            "Adapter corpus traces",
            "Opt into redacted v0.12.2 trace excerpts as adapter corpus input.",
            SettingValueType::Bool,
            "false",
            "learning.adapter_training.capture_traces",
            SettingRestartRequirement::Live,
            "Trace text is redacted again at corpus-build time.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.trace_lookback_days",
            SettingsGroup::Personalization,
            "Adapter trace lookback",
            "Days of trace artifacts eligible for adapter corpus excerpts.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(365),
            },
            "14",
            "learning.adapter_training.trace_lookback_days",
            SettingRestartRequirement::Live,
            "Trace inclusion is ignored unless capture_traces is true.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.default_lora_rank",
            SettingsGroup::Personalization,
            "Default LoRA rank",
            "Default LoRA rank for local adapter training.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(256),
            },
            "8",
            "learning.adapter_training.default_lora_rank",
            SettingRestartRequirement::Live,
            "Must be less than or equal to max_lora_rank.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.max_lora_rank",
            SettingsGroup::Personalization,
            "Max LoRA rank",
            "Maximum allowed LoRA rank for local adapter training.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(256),
            },
            "64",
            "learning.adapter_training.max_lora_rank",
            SettingRestartRequirement::Live,
            "Higher rank can increase memory use and training time.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.default_alpha",
            SettingsGroup::Personalization,
            "Default LoRA alpha",
            "Default LoRA alpha for local adapter training.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(1024),
            },
            "16",
            "learning.adapter_training.default_alpha",
            SettingRestartRequirement::Live,
            "Mapped into kernel-built trainer arguments.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.default_learning_rate",
            SettingsGroup::Personalization,
            "Default learning rate",
            "Default positive learning rate for local adapter training.",
            SettingValueType::Float {
                min: Some(0.0000001),
                max: Some(1.0),
            },
            "0.0001",
            "learning.adapter_training.default_learning_rate",
            SettingRestartRequirement::Live,
            "Mapped into kernel-built trainer arguments.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.default_max_steps",
            SettingsGroup::Personalization,
            "Default max steps",
            "Default trainer step count for local adapter training.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(1_000_000),
            },
            "200",
            "learning.adapter_training.default_max_steps",
            SettingRestartRequirement::Live,
            "Higher values consume more local compute budget.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.default_batch_size",
            SettingsGroup::Personalization,
            "Default batch size",
            "Default trainer batch size for local adapter training.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(1024),
            },
            "4",
            "learning.adapter_training.default_batch_size",
            SettingRestartRequirement::Live,
            "Mapped into kernel-built trainer arguments.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.default_seed",
            SettingsGroup::Personalization,
            "Default adapter seed",
            "Default deterministic seed for local adapter training.",
            SettingValueType::UnsignedInteger {
                min: Some(0),
                max: Some(i64::MAX as u64),
            },
            "42",
            "learning.adapter_training.default_seed",
            SettingRestartRequirement::Live,
            "Changing the seed changes reproducibility for future runs only.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.min_golden_pass_rate",
            SettingsGroup::Personalization,
            "Minimum golden pass rate",
            "Minimum fixed-eval pass rate required for ready-for-review adapter status.",
            SettingValueType::Float {
                min: Some(0.0),
                max: Some(1.0),
            },
            "0.85",
            "learning.adapter_training.min_golden_pass_rate",
            SettingRestartRequirement::Live,
            "Lower thresholds make adapter approval less strict.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.keep_rejected_runs",
            SettingsGroup::Personalization,
            "Keep rejected adapter runs",
            "Preserve rejected adapter run directories for forensic review.",
            SettingValueType::Bool,
            "false",
            "learning.adapter_training.keep_rejected_runs",
            SettingRestartRequirement::Live,
            "When false, rejecting an adapter approval deletes its run directory.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.max_log_bytes",
            SettingsGroup::Personalization,
            "Adapter max log bytes",
            "Maximum stdout/stderr bytes retained per trainer stream.",
            SettingValueType::UnsignedInteger {
                min: Some(1024),
                max: Some(1024 * 1024 * 1024),
            },
            "16777216",
            "learning.adapter_training.max_log_bytes",
            SettingRestartRequirement::Live,
            "Excess trainer output is truncated with a marker.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.adapter_training.cancel_grace_seconds",
            SettingsGroup::Personalization,
            "Adapter cancel grace",
            "Seconds to wait after SIGTERM before force-killing a trainer subprocess.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(600),
            },
            "30",
            "learning.adapter_training.cancel_grace_seconds",
            SettingRestartRequirement::Live,
            "Only affects future cancellation attempts.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.personality_digest.enabled",
            SettingsGroup::Learning,
            "Personality digest",
            "Enable the reviewed personality-digest job.",
            SettingValueType::Bool,
            "false",
            "learning.personality_digest.enabled",
            SettingRestartRequirement::Live,
            "Digest output remains a reviewed draft.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "learning.personality_digest.output_path",
            SettingsGroup::Learning,
            "Personality output path",
            "Profile-relative markdown path for accepted personality digest output.",
            SettingValueType::Path(SettingPathPolicy::AllbertHomeRelative),
            "PERSONALITY.md",
            "learning.personality_digest.output_path",
            SettingRestartRequirement::Live,
            "Must stay inside ALLBERT_HOME and cannot target reserved runtime paths.",
            SettingRedactionPolicy::Path,
        ),
        descriptor(
            "learning.personality_digest.include_episodes",
            SettingsGroup::Learning,
            "Include episodes",
            "Allow bounded episode summaries in personality digest input.",
            SettingValueType::Bool,
            "true",
            "learning.personality_digest.include_episodes",
            SettingRestartRequirement::Live,
            "Episodes are labelled as working-history-derived input.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_improvement.source_checkout",
            SettingsGroup::SelfImprovement,
            "Source checkout",
            "Path to the trusted Allbert source checkout used for self-improvement.",
            SettingValueType::OptionalPath(SettingPathPolicy::FilesystemPath),
            "",
            "self_improvement.source_checkout",
            SettingRestartRequirement::Live,
            "Changing this changes where rebuild proposals read source from.",
            SettingRedactionPolicy::Path,
        ),
        descriptor(
            "self_improvement.worktree_root",
            SettingsGroup::SelfImprovement,
            "Worktree root",
            "Directory where rebuild sibling worktrees are created.",
            SettingValueType::Path(SettingPathPolicy::FilesystemPath),
            "~/.allbert/worktrees",
            "self_improvement.worktree_root",
            SettingRestartRequirement::Live,
            "Must not point at reserved runtime directories.",
            SettingRedactionPolicy::Path,
        ),
        descriptor(
            "self_improvement.max_worktree_gb",
            SettingsGroup::SelfImprovement,
            "Worktree disk cap",
            "Maximum self-improvement worktree footprint in GiB.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(1024),
            },
            "10",
            "self_improvement.max_worktree_gb",
            SettingRestartRequirement::Live,
            "Used as a guardrail before creating rebuild worktrees.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_improvement.install_mode",
            SettingsGroup::SelfImprovement,
            "Install mode",
            "How accepted rebuild patches are applied.",
            SettingValueType::Enum(&["apply-to-current-branch"]),
            "apply-to-current-branch",
            "self_improvement.install_mode",
            SettingRestartRequirement::Live,
            "No setting enables automatic binary swaps.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "self_improvement.keep_rejected_worktree",
            SettingsGroup::SelfImprovement,
            "Keep rejected worktree",
            "Keep rebuild worktrees after rejection for manual inspection.",
            SettingValueType::Bool,
            "false",
            "self_improvement.keep_rejected_worktree",
            SettingRestartRequirement::Live,
            "Rejected artifacts remain inactive.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "scripting.engine",
            SettingsGroup::SelfImprovement,
            "Scripting engine",
            "Embedded scripting engine posture.",
            SettingValueType::Enum(&["disabled", "lua"]),
            "disabled",
            "scripting.engine",
            SettingRestartRequirement::Restart,
            "Lua remains opt-in through config and exec policy.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "model.provider",
            SettingsGroup::Providers,
            "Provider",
            "Default model provider.",
            SettingValueType::Enum(&["anthropic", "openrouter", "openai", "gemini", "ollama"]),
            "ollama",
            "model.provider",
            SettingRestartRequirement::Restart,
            "Secrets are not managed through settings.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "model.model_id",
            SettingsGroup::Providers,
            "Model id",
            "Default model id for the selected provider.",
            SettingValueType::String,
            "gemma4",
            "model.model_id",
            SettingRestartRequirement::Restart,
            "Use a model supported by the selected provider.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "model.max_tokens",
            SettingsGroup::Providers,
            "Max output tokens",
            "Default maximum output tokens per provider call.",
            SettingValueType::UnsignedInteger {
                min: Some(1),
                max: Some(1_000_000),
            },
            "4096",
            "model.max_tokens",
            SettingRestartRequirement::Restart,
            "Provider-side limits may still apply.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "model.context_window_tokens",
            SettingsGroup::Providers,
            "Context window tokens",
            "Known context window for local status rendering, or 0 when unknown.",
            SettingValueType::UnsignedInteger {
                min: Some(0),
                max: Some(10_000_000),
            },
            "0",
            "model.context_window_tokens",
            SettingRestartRequirement::Restart,
            "0 means capacity is unknown.",
            SettingRedactionPolicy::Plain,
        ),
        descriptor(
            "model.base_url",
            SettingsGroup::Providers,
            "Provider base URL",
            "Optional non-secret provider base URL.",
            SettingValueType::OptionalString,
            "http://127.0.0.1:11434",
            "model.base_url",
            SettingRestartRequirement::Restart,
            "API keys and tokens are intentionally not supported here.",
            SettingRedactionPolicy::Plain,
        ),
    ]
}

pub fn settings_for_config(config: &Config) -> Vec<SettingView> {
    let defaults = Config::default_template();
    settings_catalog()
        .into_iter()
        .map(|descriptor| SettingView {
            key: descriptor.key.to_string(),
            group: descriptor.group,
            group_label: descriptor.group.label(),
            label: descriptor.label,
            description: descriptor.description,
            value_type: descriptor.value_type.clone(),
            default_value: setting_value_for_key(&defaults, &descriptor)
                .unwrap_or_else(|| descriptor.default_value.to_string()),
            current_value: setting_value_for_key(config, &descriptor)
                .unwrap_or_else(|| descriptor.default_value.to_string()),
            config_path: descriptor.config_path.to_string(),
            restart: descriptor.restart,
            safety_note: descriptor.safety_note,
            redaction: descriptor.redaction,
        })
        .collect()
}

pub fn find_setting(key: &str) -> Option<SettingDescriptor> {
    settings_catalog()
        .into_iter()
        .find(|descriptor| descriptor.key == key.trim())
}

pub fn validate_setting_value(key: &str, raw: &str) -> Result<(), SettingValidationError> {
    validate_key_shape(key)?;
    if looks_like_secret_key(key) {
        return Err(SettingValidationError::SecretLikeKey(
            key.trim().to_string(),
        ));
    }
    let Some(descriptor) = find_setting(key) else {
        return Err(SettingValidationError::UnsupportedKey(
            key.trim().to_string(),
        ));
    };
    if descriptor.key == "trace.redaction.secrets" && raw.trim() != descriptor.default_value {
        return Err(SettingValidationError::InvalidValue {
            key: descriptor.key.to_string(),
            reason: "trace secret redaction is read-only and must remain `always`".into(),
        });
    }
    if !matches!(
        descriptor.value_type,
        SettingValueType::Path(_)
            | SettingValueType::OptionalPath(_)
            | SettingValueType::StringList
    ) && looks_like_secret_value(raw)
    {
        return Err(SettingValidationError::InvalidValue {
            key: descriptor.key.to_string(),
            reason: "value looks like a secret; use the secret-management path instead".into(),
        });
    }
    validate_value(&descriptor, raw)
}

pub fn persist_setting_value(
    paths: &AllbertPaths,
    key: &str,
    raw: &str,
) -> Result<SettingMutation, SettingPersistenceError> {
    validate_setting_value(key, raw)?;
    let descriptor = find_setting(key).expect("validated setting must exist");
    if descriptor.key == "trace.redaction.secrets" {
        return Err(SettingPersistenceError::Validation(
            SettingValidationError::InvalidValue {
                key: descriptor.key.to_string(),
                reason: "trace secret redaction is read-only and must remain `always`".into(),
            },
        ));
    }
    let mut document = load_config_document(paths)?;
    let previous_value = document_value_for_descriptor(&document, &descriptor);
    set_document_value(&mut document, &descriptor, raw)?;
    write_validated_document(paths, &descriptor, &document)?;
    Ok(SettingMutation {
        key: descriptor.key.to_string(),
        config_path: descriptor.config_path.to_string(),
        previous_value,
        new_value: Some(raw.trim().to_string()),
        changed: true,
    })
}

pub fn reset_setting_value(
    paths: &AllbertPaths,
    key: &str,
) -> Result<SettingMutation, SettingPersistenceError> {
    validate_key_shape(key)?;
    if looks_like_secret_key(key) {
        return Err(SettingPersistenceError::Validation(
            SettingValidationError::SecretLikeKey(key.trim().to_string()),
        ));
    }
    let Some(descriptor) = find_setting(key) else {
        return Err(SettingPersistenceError::Validation(
            SettingValidationError::UnsupportedKey(key.trim().to_string()),
        ));
    };
    if descriptor.key == "trace.redaction.secrets" {
        return Err(SettingPersistenceError::Validation(
            SettingValidationError::InvalidValue {
                key: descriptor.key.to_string(),
                reason: "trace secret redaction is read-only and must remain `always`".into(),
            },
        ));
    }
    let mut document = load_config_document(paths)?;
    let previous_value = document_value_for_descriptor(&document, &descriptor);
    let changed = remove_document_value(&mut document, &descriptor)?;
    if changed {
        write_validated_document(paths, &descriptor, &document)?;
    }
    Ok(SettingMutation {
        key: descriptor.key.to_string(),
        config_path: descriptor.config_path.to_string(),
        previous_value,
        new_value: None,
        changed,
    })
}

pub fn settings_catalog_errors(catalog: &[SettingDescriptor]) -> Vec<String> {
    let mut errors = Vec::new();
    let mut seen_keys = BTreeSet::new();
    for descriptor in catalog {
        if !seen_keys.insert(descriptor.key) {
            errors.push(format!("duplicate setting key {}", descriptor.key));
        }
        if descriptor.key != descriptor.config_path {
            errors.push(format!(
                "{} has mismatched config path {}",
                descriptor.key, descriptor.config_path
            ));
        }
        if descriptor.label.trim().is_empty() {
            errors.push(format!("{} has empty label", descriptor.key));
        }
        if descriptor.description.trim().is_empty() {
            errors.push(format!("{} has empty description", descriptor.key));
        }
        if descriptor.safety_note.trim().is_empty() {
            errors.push(format!("{} has empty safety note", descriptor.key));
        }
        if matches!(descriptor.redaction, SettingRedactionPolicy::Redacted) {
            errors.push(format!(
                "{} is redacted but secrets are not allowed in the settings catalog",
                descriptor.key
            ));
        }
        if validate_setting_value(descriptor.key, descriptor.default_value).is_err() {
            errors.push(format!("{} has invalid default", descriptor.key));
        }
    }
    for group in SettingsGroup::ALL {
        if !catalog.iter().any(|descriptor| descriptor.group == group) {
            errors.push(format!("group {} has no settings", group.id()));
        }
    }
    errors
}

#[allow(clippy::too_many_arguments)]
fn descriptor(
    key: &'static str,
    group: SettingsGroup,
    label: &'static str,
    description: &'static str,
    value_type: SettingValueType,
    default_value: &'static str,
    config_path: &'static str,
    restart: SettingRestartRequirement,
    safety_note: &'static str,
    redaction: SettingRedactionPolicy,
) -> SettingDescriptor {
    SettingDescriptor {
        key,
        group,
        label,
        description,
        value_type,
        default_value,
        config_path,
        restart,
        safety_note,
        redaction,
    }
}

fn load_config_document(
    paths: &AllbertPaths,
) -> Result<toml_edit::DocumentMut, SettingPersistenceError> {
    let raw =
        std::fs::read_to_string(&paths.config).map_err(|source| SettingPersistenceError::Read {
            path: paths.config.display().to_string(),
            source,
        })?;
    raw.parse::<toml_edit::DocumentMut>()
        .map_err(|err| SettingPersistenceError::Parse {
            path: paths.config.display().to_string(),
            message: err.to_string(),
        })
}

fn write_validated_document(
    paths: &AllbertPaths,
    descriptor: &SettingDescriptor,
    document: &toml_edit::DocumentMut,
) -> Result<(), SettingPersistenceError> {
    let rendered = document.to_string();
    let parsed = toml::from_str::<Config>(&rendered).map_err(|err| {
        SettingPersistenceError::RenderedConfigInvalid {
            key: descriptor.key.to_string(),
            message: err.to_string(),
        }
    })?;
    parsed
        .validate()
        .map_err(|message| SettingPersistenceError::RenderedConfigInvalid {
            key: descriptor.key.to_string(),
            message,
        })?;
    atomic_write(&paths.config, rendered.as_bytes()).map_err(|source| {
        SettingPersistenceError::Write {
            path: paths.config.display().to_string(),
            source,
        }
    })
}

fn set_document_value(
    document: &mut toml_edit::DocumentMut,
    descriptor: &SettingDescriptor,
    raw: &str,
) -> Result<(), SettingPersistenceError> {
    let segments = split_key(descriptor.key);
    let value = item_for_descriptor(descriptor, raw)?;
    let table = ensure_parent_table(document, descriptor.key, &segments)?;
    let leaf = segments
        .last()
        .expect("setting keys always contain at least one segment");
    table[leaf] = value;
    Ok(())
}

fn remove_document_value(
    document: &mut toml_edit::DocumentMut,
    descriptor: &SettingDescriptor,
) -> Result<bool, SettingPersistenceError> {
    let segments = split_key(descriptor.key);
    let Some(table) = parent_table_mut(document, descriptor.key, &segments)? else {
        return Ok(false);
    };
    let leaf = segments
        .last()
        .expect("setting keys always contain at least one segment");
    Ok(table.remove(leaf).is_some())
}

fn ensure_parent_table<'a>(
    document: &'a mut toml_edit::DocumentMut,
    key: &str,
    segments: &[&str],
) -> Result<&'a mut toml_edit::Table, SettingPersistenceError> {
    let mut item = document.as_item_mut();
    for segment in &segments[..segments.len().saturating_sub(1)] {
        if !item.is_table() {
            return Err(unsafe_edit(key, format!("`{segment}` is not a TOML table")));
        }
        let table = item.as_table_mut().expect("checked table");
        if !table.contains_key(segment) {
            table[segment] = toml_edit::Item::Table(toml_edit::Table::new());
        }
        item = table
            .get_mut(segment)
            .ok_or_else(|| unsafe_edit(key, format!("cannot create table `{segment}`")))?;
    }
    item.as_table_mut()
        .ok_or_else(|| unsafe_edit(key, "parent path is not a TOML table"))
}

fn parent_table_mut<'a>(
    document: &'a mut toml_edit::DocumentMut,
    key: &str,
    segments: &[&str],
) -> Result<Option<&'a mut toml_edit::Table>, SettingPersistenceError> {
    let mut item = document.as_item_mut();
    for segment in &segments[..segments.len().saturating_sub(1)] {
        if !item.is_table() {
            return Err(unsafe_edit(key, format!("`{segment}` is not a TOML table")));
        }
        let table = item.as_table_mut().expect("checked table");
        let Some(next) = table.get_mut(segment) else {
            return Ok(None);
        };
        item = next;
    }
    item.as_table_mut()
        .map(Some)
        .ok_or_else(|| unsafe_edit(key, "parent path is not a TOML table"))
}

fn document_value_for_descriptor(
    document: &toml_edit::DocumentMut,
    descriptor: &SettingDescriptor,
) -> Option<String> {
    let mut item = document.as_item();
    for segment in split_key(descriptor.key) {
        item = item.get(segment)?;
    }
    Some(match item {
        toml_edit::Item::Value(value) => value_to_display(value),
        toml_edit::Item::None => return None,
        other => other.to_string().trim().to_string(),
    })
}

fn item_for_descriptor(
    descriptor: &SettingDescriptor,
    raw: &str,
) -> Result<toml_edit::Item, SettingPersistenceError> {
    let value = raw.trim();
    let item = match &descriptor.value_type {
        SettingValueType::Bool => toml_edit::value(parse_bool(value).expect("validated bool")),
        SettingValueType::UnsignedInteger { .. } => {
            let parsed = value.parse::<i64>().map_err(|_| {
                SettingPersistenceError::RenderedConfigInvalid {
                    key: descriptor.key.to_string(),
                    message: "validated integer could not be rendered".into(),
                }
            })?;
            toml_edit::value(parsed)
        }
        SettingValueType::Float { .. } => {
            let parsed = value.parse::<f64>().map_err(|_| {
                SettingPersistenceError::RenderedConfigInvalid {
                    key: descriptor.key.to_string(),
                    message: "validated float could not be rendered".into(),
                }
            })?;
            toml_edit::value(parsed)
        }
        SettingValueType::String | SettingValueType::OptionalString => toml_edit::value(value),
        SettingValueType::Enum(values) => {
            let normalized = value.replace('_', "-").to_ascii_lowercase();
            let canonical = values
                .iter()
                .find(|allowed| allowed.replace('_', "-") == normalized)
                .copied()
                .unwrap_or(value);
            toml_edit::value(canonical)
        }
        SettingValueType::StringList => {
            let mut array = toml_edit::Array::default();
            for item in parse_string_list(value) {
                array.push(item);
            }
            toml_edit::value(array)
        }
        SettingValueType::Path(_) | SettingValueType::OptionalPath(_) => toml_edit::value(value),
    };
    Ok(item)
}

fn value_to_display(value: &toml_edit::Value) -> String {
    match value {
        toml_edit::Value::String(value) => value.value().to_string(),
        toml_edit::Value::Integer(value) => value.value().to_string(),
        toml_edit::Value::Float(value) => value.value().to_string(),
        toml_edit::Value::Boolean(value) => value.value().to_string(),
        toml_edit::Value::Array(array) => array
            .iter()
            .map(|item| match item {
                toml_edit::Value::String(value) => value.value().to_string(),
                other => other.to_string(),
            })
            .collect::<Vec<_>>()
            .join(","),
        other => other.to_string(),
    }
}

fn split_key(key: &str) -> Vec<&str> {
    key.split('.').collect()
}

fn unsafe_edit(key: &str, hint: impl Into<String>) -> SettingPersistenceError {
    SettingPersistenceError::UnsafeEdit {
        key: key.to_string(),
        hint: hint.into(),
    }
}

fn validate_key_shape(key: &str) -> Result<(), SettingValidationError> {
    let trimmed = key.trim();
    if trimmed.contains('=')
        || trimmed.contains('\n')
        || trimmed.contains('[')
        || trimmed.contains(']')
        || trimmed.contains('"')
        || trimmed.contains('\'')
        || trimmed.split_whitespace().count() > 1
    {
        return Err(SettingValidationError::ArbitraryTomlEdit(
            trimmed.to_string(),
        ));
    }
    Ok(())
}

fn validate_value(descriptor: &SettingDescriptor, raw: &str) -> Result<(), SettingValidationError> {
    let value = raw.trim();
    match &descriptor.value_type {
        SettingValueType::Bool => {
            parse_bool(value).ok_or_else(|| invalid(descriptor, "expected true or false"))?;
        }
        SettingValueType::UnsignedInteger { min, max } => {
            let parsed = value
                .parse::<u64>()
                .map_err(|_| invalid(descriptor, "expected an unsigned integer"))?;
            if min.is_some_and(|min| parsed < min) || max.is_some_and(|max| parsed > max) {
                return Err(invalid(
                    descriptor,
                    "value is outside the supported range for this setting",
                ));
            }
        }
        SettingValueType::Float { min, max } => {
            let parsed = value
                .parse::<f64>()
                .map_err(|_| invalid(descriptor, "expected a number"))?;
            if !parsed.is_finite()
                || min.is_some_and(|min| parsed < min)
                || max.is_some_and(|max| parsed > max)
            {
                return Err(invalid(
                    descriptor,
                    "value is outside the supported range for this setting",
                ));
            }
        }
        SettingValueType::String => {
            if value.is_empty() {
                return Err(invalid(descriptor, "value must not be empty"));
            }
        }
        SettingValueType::OptionalString => {}
        SettingValueType::Enum(values) => {
            let normalized = value.replace('-', "_").to_ascii_lowercase();
            if !values
                .iter()
                .any(|allowed| allowed.replace('-', "_") == normalized)
            {
                return Err(invalid(
                    descriptor,
                    "value is not one of the allowed enum variants",
                ));
            }
        }
        SettingValueType::StringList => {
            let parsed = parse_string_list(value);
            if parsed.is_empty()
                && matches!(
                    descriptor.key,
                    "repl.tui.status_line.items" | "learning.adapter_training.include_tiers"
                )
            {
                return Err(invalid(descriptor, "list must not be empty"));
            }
            if descriptor.key == "repl.tui.status_line.items" {
                for item in &parsed {
                    if !StatusLineItem::CATALOG
                        .iter()
                        .any(|allowed| allowed.label() == item)
                    {
                        return Err(invalid(
                            descriptor,
                            "list contains an unsupported status-line item",
                        ));
                    }
                }
            }
            if descriptor.key == "learning.adapter_training.allowed_backends" {
                for item in &parsed {
                    if !matches!(item.as_str(), "fake" | "mlx-lm-lora" | "llama-cpp-finetune") {
                        return Err(invalid(
                            descriptor,
                            "list contains an unsupported adapter backend",
                        ));
                    }
                }
            }
            if descriptor.key == "learning.adapter_training.include_tiers" {
                for item in &parsed {
                    if !matches!(item.as_str(), "durable" | "fact" | "episode") {
                        return Err(invalid(
                            descriptor,
                            "list contains an unsupported adapter corpus tier",
                        ));
                    }
                }
            }
            if descriptor.key == "rag.sources" {
                for item in &parsed {
                    let Some(source) = RagSourceKind::parse(item) else {
                        return Err(invalid(
                            descriptor,
                            "list contains an unsupported RAG source kind",
                        ));
                    };
                    if source == RagSourceKind::StagedMemoryReview {
                        return Err(invalid(
                            descriptor,
                            "staged_memory_review is review-only and cannot be an ordinary prompt source",
                        ));
                    }
                }
            }
            if descriptor.key == "rag.ingest.allowed_url_schemes" {
                for item in &parsed {
                    if !matches!(item.as_str(), "https" | "http") {
                        return Err(invalid(
                            descriptor,
                            "list contains an unsupported URL scheme",
                        ));
                    }
                }
            }
        }
        SettingValueType::Path(policy) => validate_path(descriptor, value, *policy, false)?,
        SettingValueType::OptionalPath(policy) => validate_path(descriptor, value, *policy, true)?,
    }
    Ok(())
}

fn validate_path(
    descriptor: &SettingDescriptor,
    value: &str,
    policy: SettingPathPolicy,
    optional: bool,
) -> Result<(), SettingValidationError> {
    if value.is_empty() {
        if optional {
            return Ok(());
        }
        return Err(invalid(descriptor, "path must not be empty"));
    }

    let path = Path::new(value);
    let normalized = value.replace('\\', "/");
    match policy {
        SettingPathPolicy::AllbertHomeRelative => {
            if path.is_absolute() || has_escape_component(path) {
                return Err(SettingValidationError::PathEscape {
                    key: descriptor.key.to_string(),
                    value: value.to_string(),
                });
            }
            if reserved_runtime_path(&normalized) {
                return Err(SettingValidationError::ReservedRuntimePath {
                    key: descriptor.key.to_string(),
                    value: value.to_string(),
                });
            }
        }
        SettingPathPolicy::FilesystemPath => {
            if !normalized.starts_with("~/.allbert/worktrees")
                && !normalized.starts_with(".tmp/")
                && (has_escape_component(path) || reserved_runtime_path(&normalized))
            {
                if has_escape_component(path) {
                    return Err(SettingValidationError::PathEscape {
                        key: descriptor.key.to_string(),
                        value: value.to_string(),
                    });
                }
                return Err(SettingValidationError::ReservedRuntimePath {
                    key: descriptor.key.to_string(),
                    value: value.to_string(),
                });
            }
        }
    }
    Ok(())
}

fn setting_value_for_key(config: &Config, descriptor: &SettingDescriptor) -> Option<String> {
    let value = match descriptor.key {
        "repl.ui" => config.repl.ui.label().to_string(),
        "repl.tui.spinner_style" => config.repl.tui.spinner_style.label().to_string(),
        "repl.tui.tick_ms" => config.repl.tui.tick_ms.to_string(),
        "repl.tui.status_line.enabled" => config.repl.tui.status_line.enabled.to_string(),
        "repl.tui.status_line.items" => config
            .repl
            .tui
            .status_line
            .items
            .iter()
            .map(|item| item.label())
            .collect::<Vec<_>>()
            .join(","),
        "operator_ux.activity.stuck_notice_after_s" => {
            config.operator_ux.activity.stuck_notice_after_s.to_string()
        }
        "operator_ux.activity.long_tool_notice_after_s" => config
            .operator_ux
            .activity
            .long_tool_notice_after_s
            .to_string(),
        "operator_ux.activity.show_activity_breadcrumbs" => config
            .operator_ux
            .activity
            .show_activity_breadcrumbs
            .to_string(),
        "intent.tool_call_retry_enabled" => config.intent.tool_call_retry_enabled.to_string(),
        "trace.enabled" => config.trace.enabled.to_string(),
        "trace.capture_messages" => config.trace.capture_messages.to_string(),
        "trace.session_disk_cap_mb" => config.trace.session_disk_cap_mb.to_string(),
        "trace.total_disk_cap_mb" => config.trace.total_disk_cap_mb.to_string(),
        "trace.retention_days" => config.trace.retention_days.to_string(),
        "trace.otel_export_dir" => config.trace.otel_export_dir.clone(),
        "trace.otel_service_name" => config.trace.otel_service_name.clone(),
        "trace.redaction.secrets" => config.trace.redaction.secrets.clone(),
        "trace.redaction.tool_args" => config.trace.redaction.tool_args.label().to_string(),
        "trace.redaction.tool_results" => config.trace.redaction.tool_results.label().to_string(),
        "trace.redaction.provider_payloads" => {
            config.trace.redaction.provider_payloads.label().to_string()
        }
        "self_diagnosis.enabled" => config.self_diagnosis.enabled.to_string(),
        "self_diagnosis.lookback_days" => config.self_diagnosis.lookback_days.to_string(),
        "self_diagnosis.max_sessions" => config.self_diagnosis.max_sessions.to_string(),
        "self_diagnosis.max_spans" => config.self_diagnosis.max_spans.to_string(),
        "self_diagnosis.max_events" => config.self_diagnosis.max_events.to_string(),
        "self_diagnosis.max_text_snippet_bytes" => {
            config.self_diagnosis.max_text_snippet_bytes.to_string()
        }
        "self_diagnosis.max_report_bytes" => config.self_diagnosis.max_report_bytes.to_string(),
        "self_diagnosis.allow_remediation" => config.self_diagnosis.allow_remediation.to_string(),
        "self_diagnosis.remediation_provider_max_tokens" => config
            .self_diagnosis
            .remediation_provider_max_tokens
            .to_string(),
        "local_utilities.enabled" => config.local_utilities.enabled.to_string(),
        "local_utilities.unix_pipe_max_stages" => {
            config.local_utilities.unix_pipe_max_stages.to_string()
        }
        "local_utilities.unix_pipe_timeout_s" => {
            config.local_utilities.unix_pipe_timeout_s.to_string()
        }
        "local_utilities.unix_pipe_max_stdin_bytes" => {
            config.local_utilities.unix_pipe_max_stdin_bytes.to_string()
        }
        "local_utilities.unix_pipe_max_stdout_bytes" => config
            .local_utilities
            .unix_pipe_max_stdout_bytes
            .to_string(),
        "local_utilities.unix_pipe_max_stderr_bytes" => config
            .local_utilities
            .unix_pipe_max_stderr_bytes
            .to_string(),
        "local_utilities.unix_pipe_max_args_per_stage" => config
            .local_utilities
            .unix_pipe_max_args_per_stage
            .to_string(),
        "local_utilities.unix_pipe_max_arg_bytes" => {
            config.local_utilities.unix_pipe_max_arg_bytes.to_string()
        }
        "local_utilities.unix_pipe_max_argv_bytes" => {
            config.local_utilities.unix_pipe_max_argv_bytes.to_string()
        }
        "memory.prefetch_enabled" => config.memory.prefetch_enabled.to_string(),
        "memory.routing.mode" => config.memory.routing.mode.label().to_string(),
        "memory.episodes.prefetch_enabled" => config.memory.episodes.prefetch_enabled.to_string(),
        "memory.semantic.enabled" => config.memory.semantic.enabled.to_string(),
        "memory.trash_retention_days" => config.memory.trash_retention_days.to_string(),
        "memory.rejected_retention_days" => config.memory.rejected_retention_days.to_string(),
        "rag.enabled" => config.rag.enabled.to_string(),
        "rag.mode" => config.rag.mode.label().to_string(),
        "rag.max_chunks_per_turn" => config.rag.max_chunks_per_turn.to_string(),
        "rag.max_chunk_bytes" => config.rag.max_chunk_bytes.to_string(),
        "rag.max_prompt_bytes" => config.rag.max_prompt_bytes.to_string(),
        "rag.refresh_after_external_evidence" => {
            config.rag.refresh_after_external_evidence.to_string()
        }
        "rag.sources" => config
            .rag
            .sources
            .iter()
            .map(|source| source.label())
            .collect::<Vec<_>>()
            .join(","),
        "rag.include_inactive_skill_bodies" => config.rag.include_inactive_skill_bodies.to_string(),
        "rag.vector.enabled" => config.rag.vector.enabled.to_string(),
        "rag.vector.provider" => config.rag.vector.provider.label().to_string(),
        "rag.vector.model" => config.rag.vector.model.clone(),
        "rag.vector.base_url" => config.rag.vector.base_url.clone(),
        "rag.vector.distance" => config.rag.vector.distance.label().to_string(),
        "rag.vector.batch_size" => config.rag.vector.batch_size.to_string(),
        "rag.vector.query_timeout_s" => config.rag.vector.query_timeout_s.to_string(),
        "rag.vector.index_timeout_s" => config.rag.vector.index_timeout_s.to_string(),
        "rag.vector.max_query_bytes" => config.rag.vector.max_query_bytes.to_string(),
        "rag.vector.max_concurrent_queries" => config.rag.vector.max_concurrent_queries.to_string(),
        "rag.vector.retry_attempts" => config.rag.vector.retry_attempts.to_string(),
        "rag.vector.fallback_to_lexical" => config.rag.vector.fallback_to_lexical.to_string(),
        "rag.vector.fusion_vector_weight" => config.rag.vector.fusion_vector_weight.to_string(),
        "rag.index.auto_maintain" => config.rag.index.auto_maintain.to_string(),
        "rag.index.schedule_enabled" => config.rag.index.schedule_enabled.to_string(),
        "rag.index.schedule" => config.rag.index.schedule.clone(),
        "rag.index.stale_only" => config.rag.index.stale_only.to_string(),
        "rag.index.run_on_startup_if_missing" => {
            config.rag.index.run_on_startup_if_missing.to_string()
        }
        "rag.index.coalesce_missed_runs" => config.rag.index.coalesce_missed_runs.to_string(),
        "rag.index.shutdown_grace_s" => config.rag.index.shutdown_grace_s.to_string(),
        "rag.index.max_run_seconds" => config.rag.index.max_run_seconds.to_string(),
        "rag.index.max_chunks_per_run" => config.rag.index.max_chunks_per_run.to_string(),
        "rag.ingest.max_files_per_collection" => {
            config.rag.ingest.max_files_per_collection.to_string()
        }
        "rag.ingest.max_file_bytes" => config.rag.ingest.max_file_bytes.to_string(),
        "rag.ingest.max_collection_bytes" => config.rag.ingest.max_collection_bytes.to_string(),
        "rag.ingest.allowed_url_schemes" => config.rag.ingest.allowed_url_schemes.join(","),
        "rag.ingest.allow_insecure_http" => config.rag.ingest.allow_insecure_http.to_string(),
        "rag.ingest.url_depth" => config.rag.ingest.url_depth.to_string(),
        "rag.ingest.url_max_pages" => config.rag.ingest.url_max_pages.to_string(),
        "rag.ingest.url_max_bytes" => config.rag.ingest.url_max_bytes.to_string(),
        "rag.ingest.url_max_redirects" => config.rag.ingest.url_max_redirects.to_string(),
        "rag.ingest.fetch_timeout_s" => config.rag.ingest.fetch_timeout_s.to_string(),
        "rag.ingest.respect_robots_txt" => config.rag.ingest.respect_robots_txt.to_string(),
        "rag.ingest.allowed_content_types" => config.rag.ingest.allowed_content_types.join(","),
        "rag.ingest.user_agent" => config.rag.ingest.user_agent.clone(),
        "learning.enabled" => config.learning.enabled.to_string(),
        "learning.compute_cap_wall_seconds" => config
            .learning
            .compute_cap_wall_seconds
            .map(|value| value.to_string())
            .unwrap_or_else(|| "0".into()),
        "learning.adapter_training.enabled" => config.learning.adapter_training.enabled.to_string(),
        "learning.adapter_training.allowed_backends" => {
            config.learning.adapter_training.allowed_backends.join(",")
        }
        "learning.adapter_training.default_backend" => config
            .learning
            .adapter_training
            .default_backend
            .clone()
            .unwrap_or_default(),
        "learning.adapter_training.schedule" => config.learning.adapter_training.schedule.clone(),
        "learning.adapter_training.include_tiers" => {
            config.learning.adapter_training.include_tiers.join(",")
        }
        "learning.adapter_training.include_episodes" => config
            .learning
            .adapter_training
            .include_episodes
            .to_string(),
        "learning.adapter_training.episode_lookback_days" => config
            .learning
            .adapter_training
            .episode_lookback_days
            .to_string(),
        "learning.adapter_training.max_episode_summaries" => config
            .learning
            .adapter_training
            .max_episode_summaries
            .to_string(),
        "learning.adapter_training.max_input_bytes" => {
            config.learning.adapter_training.max_input_bytes.to_string()
        }
        "learning.adapter_training.max_output_artifact_bytes" => config
            .learning
            .adapter_training
            .max_output_artifact_bytes
            .to_string(),
        "learning.adapter_training.capture_traces" => {
            config.learning.adapter_training.capture_traces.to_string()
        }
        "learning.adapter_training.trace_lookback_days" => config
            .learning
            .adapter_training
            .trace_lookback_days
            .to_string(),
        "learning.adapter_training.default_lora_rank" => config
            .learning
            .adapter_training
            .default_lora_rank
            .to_string(),
        "learning.adapter_training.max_lora_rank" => {
            config.learning.adapter_training.max_lora_rank.to_string()
        }
        "learning.adapter_training.default_alpha" => {
            config.learning.adapter_training.default_alpha.to_string()
        }
        "learning.adapter_training.default_learning_rate" => config
            .learning
            .adapter_training
            .default_learning_rate
            .clone(),
        "learning.adapter_training.default_max_steps" => config
            .learning
            .adapter_training
            .default_max_steps
            .to_string(),
        "learning.adapter_training.default_batch_size" => config
            .learning
            .adapter_training
            .default_batch_size
            .to_string(),
        "learning.adapter_training.default_seed" => {
            config.learning.adapter_training.default_seed.to_string()
        }
        "learning.adapter_training.min_golden_pass_rate" => config
            .learning
            .adapter_training
            .min_golden_pass_rate
            .clone(),
        "learning.adapter_training.keep_rejected_runs" => config
            .learning
            .adapter_training
            .keep_rejected_runs
            .to_string(),
        "learning.adapter_training.max_log_bytes" => {
            config.learning.adapter_training.max_log_bytes.to_string()
        }
        "learning.adapter_training.cancel_grace_seconds" => config
            .learning
            .adapter_training
            .cancel_grace_seconds
            .to_string(),
        "learning.personality_digest.enabled" => {
            config.learning.personality_digest.enabled.to_string()
        }
        "learning.personality_digest.output_path" => {
            config.learning.personality_digest.output_path.clone()
        }
        "learning.personality_digest.include_episodes" => config
            .learning
            .personality_digest
            .include_episodes
            .to_string(),
        "self_improvement.source_checkout" => config
            .self_improvement
            .source_checkout
            .as_ref()
            .map(|path| path.display().to_string())
            .unwrap_or_default(),
        "self_improvement.worktree_root" => {
            config.self_improvement.worktree_root.display().to_string()
        }
        "self_improvement.max_worktree_gb" => config.self_improvement.max_worktree_gb.to_string(),
        "self_improvement.install_mode" => config.self_improvement.install_mode.label().to_string(),
        "self_improvement.keep_rejected_worktree" => {
            config.self_improvement.keep_rejected_worktree.to_string()
        }
        "scripting.engine" => config.scripting.engine.label().to_string(),
        "model.provider" => config.model.provider.label().to_string(),
        "model.model_id" => config.model.model_id.clone(),
        "model.max_tokens" => config.model.max_tokens.to_string(),
        "model.context_window_tokens" => config.model.context_window_tokens.to_string(),
        "model.base_url" => config.model.base_url.clone().unwrap_or_default(),
        _ => return None,
    };
    Some(value)
}

fn invalid(descriptor: &SettingDescriptor, reason: &str) -> SettingValidationError {
    SettingValidationError::InvalidValue {
        key: descriptor.key.to_string(),
        reason: reason.to_string(),
    }
}

fn parse_bool(value: &str) -> Option<bool> {
    match value.to_ascii_lowercase().as_str() {
        "true" | "yes" | "on" | "1" => Some(true),
        "false" | "no" | "off" | "0" => Some(false),
        _ => None,
    }
}

fn parse_string_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(|item| item.replace('-', "_").to_ascii_lowercase())
        .collect()
}

fn looks_like_secret_key(value: &str) -> bool {
    let lowered = value.to_ascii_lowercase();
    if lowered.contains("api_key") || lowered.contains("apikey") || lowered.contains("key_env") {
        return true;
    }
    lowered
        .split(['.', '_', '-'])
        .any(|segment| matches!(segment, "secret" | "token" | "password" | "key"))
}

fn looks_like_secret_value(value: &str) -> bool {
    let lowered = value.to_ascii_lowercase();
    lowered.starts_with("sk-")
        || lowered.contains("api_key=")
        || lowered.contains("apikey=")
        || lowered.contains("token=")
        || lowered.contains("secret=")
        || lowered.contains("password=")
}

fn has_escape_component(path: &Path) -> bool {
    path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    })
}

fn reserved_runtime_path(normalized: &str) -> bool {
    let normalized = normalized.trim_start_matches("./").to_ascii_lowercase();
    [
        "secrets/",
        "run/",
        "logs/",
        "traces/",
        "memory/",
        "jobs/",
        "skills/",
        "sessions/",
        "config.toml",
        "soul.md",
        "user.md",
        "identity.md",
        "tools.md",
        "agents.md",
        "heartbeat.md",
    ]
    .iter()
    .any(|reserved| {
        normalized == reserved.trim_end_matches('/') || normalized.starts_with(reserved)
    })
}

#[allow(dead_code)]
fn _typed_parsing_reaches_existing_config_types() {
    let _ = ReplUiMode::parse("tui");
    let _ = MemoryRoutingMode::AlwaysEligible.label();
    let _ = ScriptingEngineConfig::Lua.label();
    let _ = Provider::parse("ollama");
    let _ = TuiSpinnerStyle::parse("braille");
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    fn test_paths() -> (tempfile::TempDir, AllbertPaths) {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join("home"));
        fs::create_dir_all(&paths.root).expect("home dir");
        fs::write(
            &paths.config,
            format!(
                r#"# keep top comment
[setup]
version = {}

[model]
# keep provider comment
provider = "ollama"
model_id = "gemma4"
base_url = "http://127.0.0.1:11434"
max_tokens = 4096
context_window_tokens = 0

[repl]
ui = "tui"
show_inbox_on_attach = true

[repl.tui.status_line]
enabled = true
items = ["model", "cost"]

[memory]
prefetch_enabled = true
trash_retention_days = 30
rejected_retention_days = 30

[learning.personality_digest]
output_path = "PERSONALITY.md"

[custom]
keep = "yes"
"#,
                crate::CURRENT_SETUP_VERSION
            ),
        )
        .expect("write config");
        (temp, paths)
    }

    #[test]
    fn settings_catalog_is_complete_and_described() {
        let catalog = settings_catalog();
        let errors = settings_catalog_errors(&catalog);
        assert!(errors.is_empty(), "{}", errors.join("\n"));
        for group in SettingsGroup::ALL {
            assert!(
                catalog.iter().any(|descriptor| descriptor.group == group),
                "missing group {}",
                group.id()
            );
        }
    }

    #[test]
    fn settings_view_reports_defaults_and_current_values() {
        let mut config = Config::default_template();
        config.repl.ui = ReplUiMode::Classic;
        config.memory.prefetch_enabled = false;
        config.model.provider = Provider::Openai;
        config.model.model_id = "gpt-test".into();

        let views = settings_for_config(&config);
        let repl = views
            .iter()
            .find(|view| view.key == "repl.ui")
            .expect("repl.ui view");
        assert_eq!(repl.default_value, "tui");
        assert_eq!(repl.current_value, "classic");
        assert_eq!(repl.restart, SettingRestartRequirement::Restart);

        let model = views
            .iter()
            .find(|view| view.key == "model.model_id")
            .expect("model.model_id view");
        assert_eq!(model.default_value, "gemma4");
        assert_eq!(model.current_value, "gpt-test");

        let rag = views
            .iter()
            .find(|view| view.key == "rag.mode")
            .expect("rag.mode view");
        assert_eq!(rag.group, SettingsGroup::Rag);
        assert_eq!(rag.default_value, "hybrid");
        assert_eq!(rag.current_value, "hybrid");
    }

    #[test]
    fn settings_validation_accepts_typed_values() {
        validate_setting_value("repl.ui", "classic").expect("enum should validate");
        validate_setting_value("repl.tui.status_line.enabled", "false")
            .expect("bool should validate");
        validate_setting_value("model.max_tokens", "8192").expect("integer should validate");
        validate_setting_value("repl.tui.status_line.items", "model,cost,trace")
            .expect("list should validate");
        validate_setting_value("learning.personality_digest.output_path", "PERSONALITY.md")
            .expect("path should validate");
        validate_setting_value("trace.redaction.provider_payloads", "summary")
            .expect("trace field policy should validate");
        validate_setting_value("intent.tool_call_retry_enabled", "true")
            .expect("intent retry bool should validate");
        validate_setting_value("self_diagnosis.remediation_provider_max_tokens", "4096")
            .expect("remediation token cap should validate");
        validate_setting_value("rag.mode", "hybrid").expect("rag mode should validate");
        validate_setting_value("rag.sources", "operator_docs,commands,settings,memory")
            .expect("rag sources should accept aliases");
        validate_setting_value("rag.vector.provider", "ollama")
            .expect("rag vector provider should validate");
        validate_setting_value("rag.vector.fusion_vector_weight", "0.7")
            .expect("rag fusion weight should validate");
        validate_setting_value("rag.index.max_chunks_per_run", "5000")
            .expect("rag run chunk cap should validate");
        validate_setting_value("rag.ingest.allowed_url_schemes", "https,http")
            .expect("rag URL schemes should validate");
        validate_setting_value("rag.ingest.url_max_pages", "1")
            .expect("rag URL page cap should validate");
    }

    #[test]
    fn settings_validation_rejects_unsupported_and_invalid_values() {
        assert!(matches!(
            validate_setting_value("unknown.setting", "true"),
            Err(SettingValidationError::UnsupportedKey(_))
        ));
        assert!(matches!(
            validate_setting_value("repl.ui", "web"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
        assert!(matches!(
            validate_setting_value("model.max_tokens", "0"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
        assert!(matches!(
            validate_setting_value("repl.tui.status_line.items", "model,nope"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
        assert!(matches!(
            validate_setting_value("trace.redaction.secrets", "never"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
        assert!(matches!(
            validate_setting_value("intent.tool_call_retry_enabled", "maybe"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
        assert!(matches!(
            validate_setting_value("self_diagnosis.remediation_provider_max_tokens", "128"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
        assert!(matches!(
            validate_setting_value("rag.mode", "semantic"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
        assert!(matches!(
            validate_setting_value("rag.sources", "operator_docs,staged_memory_review"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
        assert!(matches!(
            validate_setting_value("rag.vector.fusion_vector_weight", "1.5"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
        assert!(matches!(
            validate_setting_value("rag.ingest.allowed_url_schemes", "https,ftp"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
    }

    #[test]
    fn trace_settings_are_cataloged_and_read_only_secret_redaction_is_enforced() {
        let catalog = settings_catalog();
        assert!(catalog.iter().any(|descriptor| {
            descriptor.key == "trace.enabled" && descriptor.group == SettingsGroup::Trace
        }));
        assert!(catalog.iter().any(|descriptor| {
            descriptor.key == "trace.redaction.secrets"
                && descriptor.group == SettingsGroup::Trace
                && descriptor.default_value == "always"
        }));

        validate_setting_value("trace.redaction.secrets", "always")
            .expect("secret redaction default remains valid");
        let err = validate_setting_value("trace.redaction.secrets", "drop")
            .expect_err("secret redaction cannot be weakened");
        assert!(matches!(err, SettingValidationError::InvalidValue { .. }));
    }

    #[test]
    fn settings_validation_rejects_secret_like_keys_and_values() {
        assert!(matches!(
            validate_setting_value("model.api_key_env", "OPENAI_API_KEY"),
            Err(SettingValidationError::SecretLikeKey(_))
        ));
        assert!(matches!(
            validate_setting_value("model.model_id", "sk-secret-token-value"),
            Err(SettingValidationError::InvalidValue { .. })
        ));
    }

    #[test]
    fn settings_validation_rejects_arbitrary_toml_edits() {
        assert!(matches!(
            validate_setting_value("model.provider = \"openai\"", "openai"),
            Err(SettingValidationError::ArbitraryTomlEdit(_))
        ));
        assert!(matches!(
            validate_setting_value("[model]\nprovider", "openai"),
            Err(SettingValidationError::ArbitraryTomlEdit(_))
        ));
    }

    #[test]
    fn settings_validation_rejects_path_escapes_and_reserved_paths() {
        assert!(matches!(
            validate_setting_value(
                "learning.personality_digest.output_path",
                "../PERSONALITY.md"
            ),
            Err(SettingValidationError::PathEscape { .. })
        ));
        assert!(matches!(
            validate_setting_value("learning.personality_digest.output_path", "secrets/out.md"),
            Err(SettingValidationError::ReservedRuntimePath { .. })
        ));
        assert!(matches!(
            validate_setting_value("self_improvement.worktree_root", "sessions/worktrees"),
            Err(SettingValidationError::ReservedRuntimePath { .. })
        ));
    }

    #[test]
    fn settings_persistence_preserves_comments_and_unknown_tables() {
        let (_temp, paths) = test_paths();
        let mutation =
            persist_setting_value(&paths, "model.max_tokens", "8192").expect("persist setting");
        assert_eq!(mutation.previous_value.as_deref(), Some("4096"));
        assert_eq!(mutation.new_value.as_deref(), Some("8192"));

        let raw = fs::read_to_string(&paths.config).expect("read config");
        assert!(raw.contains("# keep top comment"));
        assert!(raw.contains("# keep provider comment"));
        assert!(raw.contains("[custom]"));
        assert!(raw.contains("max_tokens = 8192"));
        let parsed: Config = toml::from_str(&raw).expect("rendered config should parse");
        assert_eq!(parsed.model.max_tokens, 8192);
    }

    #[test]
    fn settings_persistence_sets_representative_types() {
        let (_temp, paths) = test_paths();
        persist_setting_value(&paths, "repl.ui", "classic").expect("enum set");
        persist_setting_value(&paths, "memory.prefetch_enabled", "false").expect("bool set");
        persist_setting_value(&paths, "repl.tui.status_line.items", "model,cost,trace")
            .expect("list set");
        persist_setting_value(
            &paths,
            "learning.personality_digest.output_path",
            "profiles/PERSONALITY.md",
        )
        .expect("path set");

        let raw = fs::read_to_string(&paths.config).expect("read config");
        let parsed: Config = toml::from_str(&raw).expect("rendered config should parse");
        assert_eq!(parsed.repl.ui, ReplUiMode::Classic);
        assert!(!parsed.memory.prefetch_enabled);
        assert_eq!(
            parsed
                .repl
                .tui
                .status_line
                .items
                .iter()
                .map(|item| item.label())
                .collect::<Vec<_>>(),
            vec!["model", "cost", "trace"]
        );
        assert_eq!(
            parsed.learning.personality_digest.output_path,
            "profiles/PERSONALITY.md"
        );
    }

    #[test]
    fn trace_settings_persist_with_allowlist_and_keep_secret_redaction_read_only() {
        let (_temp, paths) = test_paths();
        persist_setting_value(&paths, "trace.capture_messages", "false").expect("bool set");
        persist_setting_value(&paths, "trace.redaction.provider_payloads", "summary")
            .expect("trace policy set");

        let raw = fs::read_to_string(&paths.config).expect("read config");
        assert!(raw.contains("[trace]"));
        assert!(raw.contains("capture_messages = false"));
        assert!(raw.contains("[trace.redaction]"));
        assert!(raw.contains("provider_payloads = \"summary\""));

        let parsed: Config = toml::from_str(&raw).expect("rendered config should parse");
        assert!(!parsed.trace.capture_messages);
        assert_eq!(parsed.trace.redaction.provider_payloads.label(), "summary");

        let before = fs::read_to_string(&paths.config).expect("read before");
        let err = persist_setting_value(&paths, "trace.redaction.secrets", "always")
            .expect_err("read-only trace secret redaction should not persist");
        assert!(matches!(
            err,
            SettingPersistenceError::Validation(SettingValidationError::InvalidValue { .. })
        ));
        assert_eq!(
            fs::read_to_string(&paths.config).expect("read after"),
            before
        );

        let err = reset_setting_value(&paths, "trace.redaction.secrets")
            .expect_err("read-only trace secret redaction should not reset");
        assert!(matches!(
            err,
            SettingPersistenceError::Validation(SettingValidationError::InvalidValue { .. })
        ));
    }

    #[test]
    fn settings_reset_removes_explicit_override() {
        let (_temp, paths) = test_paths();
        persist_setting_value(&paths, "memory.prefetch_enabled", "false").expect("set");
        let mutation =
            reset_setting_value(&paths, "memory.prefetch_enabled").expect("reset setting");
        assert!(mutation.changed);
        assert_eq!(mutation.previous_value.as_deref(), Some("false"));

        let raw = fs::read_to_string(&paths.config).expect("read config");
        assert!(!raw.contains("prefetch_enabled"));
        let parsed: Config = toml::from_str(&raw).expect("rendered config should parse");
        assert!(parsed.memory.prefetch_enabled);
    }

    #[test]
    fn settings_persistence_rejects_unsafe_values_without_writing() {
        let (_temp, paths) = test_paths();
        let before = fs::read_to_string(&paths.config).expect("read before");
        let err =
            persist_setting_value(&paths, "learning.personality_digest.output_path", "../x.md")
                .expect_err("path escape should fail");
        assert!(matches!(
            err,
            SettingPersistenceError::Validation(SettingValidationError::PathEscape { .. })
        ));
        assert_eq!(
            fs::read_to_string(&paths.config).expect("read after"),
            before
        );

        let err = persist_setting_value(&paths, "model.api_key_env", "OPENAI_API_KEY")
            .expect_err("secret-like key should fail");
        assert!(matches!(
            err,
            SettingPersistenceError::Validation(SettingValidationError::SecretLikeKey(_))
        ));
        assert_eq!(
            fs::read_to_string(&paths.config).expect("read final"),
            before
        );
    }

    #[test]
    fn settings_persistence_rejects_conflicting_toml_shape_without_writing() {
        let (_temp, paths) = test_paths();
        fs::write(
            &paths.config,
            r#"repl = "not a table"

[model]
provider = "ollama"
model_id = "gemma4"
max_tokens = 4096
context_window_tokens = 0
"#,
        )
        .expect("write invalid shape");
        let before = fs::read_to_string(&paths.config).expect("read before");
        let err = persist_setting_value(&paths, "repl.ui", "classic")
            .expect_err("shape conflict should fail");
        assert!(matches!(err, SettingPersistenceError::UnsafeEdit { .. }));
        assert_eq!(
            fs::read_to_string(&paths.config).expect("read after"),
            before
        );
    }
}
