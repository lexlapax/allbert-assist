use std::collections::BTreeSet;
use std::fmt;
use std::path::{Component, Path};

use crate::{
    Config, MemoryRoutingMode, Provider, ReplUiMode, ScriptingEngineConfig, StatusLineItem,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SettingsGroup {
    Ui,
    Activity,
    Memory,
    Learning,
    SelfImprovement,
    Providers,
}

impl SettingsGroup {
    pub const ALL: [Self; 6] = [
        Self::Ui,
        Self::Activity,
        Self::Memory,
        Self::Learning,
        Self::SelfImprovement,
        Self::Providers,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::Ui => "ui",
            Self::Activity => "activity",
            Self::Memory => "memory",
            Self::Learning => "learning",
            Self::SelfImprovement => "self_improvement",
            Self::Providers => "providers",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Ui => "UI",
            Self::Activity => "Activity",
            Self::Memory => "Memory",
            Self::Learning => "Learning",
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
            if parsed.is_empty() {
                return Err(invalid(descriptor, "list must not be empty"));
            }
            if descriptor.key == "repl.tui.status_line.items" {
                for item in parsed {
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
        "repl.tui.spinner_style" => "braille".to_string(),
        "repl.tui.tick_ms" => "80".to_string(),
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
        "operator_ux.activity.stuck_notice_after_s" => "30".to_string(),
        "operator_ux.activity.long_tool_notice_after_s" => "20".to_string(),
        "operator_ux.activity.show_activity_breadcrumbs" => "true".to_string(),
        "memory.prefetch_enabled" => config.memory.prefetch_enabled.to_string(),
        "memory.routing.mode" => config.memory.routing.mode.label().to_string(),
        "memory.episodes.prefetch_enabled" => config.memory.episodes.prefetch_enabled.to_string(),
        "memory.semantic.enabled" => config.memory.semantic.enabled.to_string(),
        "memory.trash_retention_days" => config.memory.trash_retention_days.to_string(),
        "memory.rejected_retention_days" => config.memory.rejected_retention_days.to_string(),
        "learning.enabled" => config.learning.enabled.to_string(),
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
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
