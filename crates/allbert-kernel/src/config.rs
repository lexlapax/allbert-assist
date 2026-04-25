use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::error::{ConfigError, KernelError};
use crate::intent::Intent;
use crate::paths::AllbertPaths;
use crate::scripting::{
    LUA_MAX_EXECUTION_MS_CEILING, LUA_MAX_MEMORY_KB_CEILING, LUA_MAX_OUTPUT_BYTES_CEILING,
};

pub const CURRENT_SETUP_VERSION: u8 = 4;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub model: ModelConfig,
    #[serde(default)]
    pub setup: SetupConfig,
    #[serde(default)]
    pub daemon: DaemonConfig,
    #[serde(default)]
    pub sessions: SessionsConfig,
    #[serde(default)]
    pub channels: ChannelsConfig,
    #[serde(default)]
    pub repl: ReplConfig,
    #[serde(default)]
    pub operator_ux: OperatorUxConfig,
    #[serde(default)]
    pub jobs: JobsConfig,
    #[serde(default)]
    pub install: InstallConfig,
    #[serde(default)]
    pub intent_classifier: IntentClassifierConfig,
    #[serde(default)]
    pub memory: MemoryConfig,
    #[serde(default)]
    pub learning: LearningConfig,
    #[serde(default)]
    pub self_improvement: SelfImprovementConfig,
    #[serde(default)]
    pub scripting: ScriptingConfig,
    #[serde(default)]
    pub security: SecurityConfig,
    #[serde(default)]
    pub limits: LimitsConfig,
    #[serde(default)]
    pub trace: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelConfig {
    pub provider: Provider,
    pub model_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key_env: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    pub max_tokens: u32,
    #[serde(default)]
    pub context_window_tokens: u32,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Anthropic,
    Openrouter,
    Openai,
    Gemini,
    Ollama,
}

impl Provider {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.to_ascii_lowercase().as_str() {
            "anthropic" => Some(Self::Anthropic),
            "openrouter" => Some(Self::Openrouter),
            "openai" => Some(Self::Openai),
            "gemini" => Some(Self::Gemini),
            "ollama" => Some(Self::Ollama),
            _ => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic",
            Self::Openrouter => "openrouter",
            Self::Openai => "openai",
            Self::Gemini => "gemini",
            Self::Ollama => "ollama",
        }
    }

    pub fn default_model_id(self) -> &'static str {
        match self {
            Self::Anthropic => "claude-sonnet-4-5",
            Self::Openrouter => "anthropic/claude-sonnet-4",
            Self::Openai => "gpt-5.4-mini",
            Self::Gemini => "gemini-2.5-flash",
            Self::Ollama => "gemma4",
        }
    }

    pub fn default_api_key_env(self) -> Option<&'static str> {
        match self {
            Self::Anthropic => Some("ANTHROPIC_API_KEY"),
            Self::Openrouter => Some("OPENROUTER_API_KEY"),
            Self::Openai => Some("OPENAI_API_KEY"),
            Self::Gemini => Some("GEMINI_API_KEY"),
            Self::Ollama => None,
        }
    }

    pub fn default_base_url(self) -> Option<&'static str> {
        match self {
            Self::Ollama => Some("http://127.0.0.1:11434"),
            _ => None,
        }
    }

    pub fn api_key_required(self) -> bool {
        self.default_api_key_env().is_some()
    }

    pub fn known_image_input_support(self, model_id: &str) -> bool {
        match self {
            Self::Anthropic | Self::Openai | Self::Gemini => true,
            Self::Openrouter => false,
            Self::Ollama => {
                let model = model_id.to_ascii_lowercase();
                model.contains("gemma4") || model.contains("llava") || model.contains("vision")
            }
        }
    }

    pub fn to_proto_kind(self) -> allbert_proto::ProviderKind {
        match self {
            Self::Anthropic => allbert_proto::ProviderKind::Anthropic,
            Self::Openrouter => allbert_proto::ProviderKind::Openrouter,
            Self::Openai => allbert_proto::ProviderKind::Openai,
            Self::Gemini => allbert_proto::ProviderKind::Gemini,
            Self::Ollama => allbert_proto::ProviderKind::Ollama,
        }
    }

    pub fn from_proto_kind(kind: allbert_proto::ProviderKind) -> Self {
        match kind {
            allbert_proto::ProviderKind::Anthropic => Self::Anthropic,
            allbert_proto::ProviderKind::Openrouter => Self::Openrouter,
            allbert_proto::ProviderKind::Openai => Self::Openai,
            allbert_proto::ProviderKind::Gemini => Self::Gemini,
            allbert_proto::ProviderKind::Ollama => Self::Ollama,
        }
    }

    pub fn model_config(self, model_id: impl Into<String>, max_tokens: u32) -> ModelConfig {
        ModelConfig {
            provider: self,
            model_id: model_id.into(),
            api_key_env: self.default_api_key_env().map(str::to_string),
            base_url: self.default_base_url().map(str::to_string),
            max_tokens,
            context_window_tokens: 0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
#[derive(Default)]
pub struct SetupConfig {
    pub version: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct DaemonConfig {
    pub socket_path: Option<PathBuf>,
    pub log_dir: Option<PathBuf>,
    pub log_retention_days: u16,
    pub session_max_age_days: u16,
    pub auto_spawn: bool,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            socket_path: None,
            log_dir: None,
            log_retention_days: 7,
            session_max_age_days: 30,
            auto_spawn: true,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CrossChannelRouting {
    Inherit,
    Scoped,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct SessionsConfig {
    pub cross_channel_routing: CrossChannelRouting,
}

impl Default for SessionsConfig {
    fn default() -> Self {
        Self {
            cross_channel_routing: CrossChannelRouting::Inherit,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct ChannelsConfig {
    pub approval_timeout_s: u64,
    pub approval_inbox_retention_days: u16,
    pub telegram: TelegramChannelConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct ReplConfig {
    pub ui: ReplUiMode,
    pub tui: TuiConfig,
    pub show_inbox_on_attach: bool,
}

impl Default for ReplConfig {
    fn default() -> Self {
        Self {
            ui: ReplUiMode::Tui,
            tui: TuiConfig::default(),
            show_inbox_on_attach: true,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReplUiMode {
    Tui,
    Classic,
}

impl ReplUiMode {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "tui" => Some(Self::Tui),
            "classic" => Some(Self::Classic),
            _ => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Tui => "tui",
            Self::Classic => "classic",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct TuiConfig {
    pub mouse: bool,
    pub max_transcript_events: usize,
    #[serde(default, deserialize_with = "deserialize_tui_spinner_style")]
    pub spinner_style: TuiSpinnerStyle,
    pub tick_ms: u64,
    pub status_line: StatusLineConfig,
}

impl Default for TuiConfig {
    fn default() -> Self {
        Self {
            mouse: true,
            max_transcript_events: 500,
            spinner_style: TuiSpinnerStyle::Braille,
            tick_ms: 80,
            status_line: StatusLineConfig::default(),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TuiSpinnerStyle {
    #[default]
    Braille,
    Dots,
    Bar,
    Off,
}

impl TuiSpinnerStyle {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().replace('-', "_").as_str() {
            "braille" => Some(Self::Braille),
            "dots" => Some(Self::Dots),
            "bar" => Some(Self::Bar),
            "off" => Some(Self::Off),
            _ => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Braille => "braille",
            Self::Dots => "dots",
            Self::Bar => "bar",
            Self::Off => "off",
        }
    }

    pub fn frames(self) -> &'static [&'static str] {
        match self {
            Self::Braille => &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
            Self::Dots => &[".", "..", "...", "...."],
            Self::Bar => &["-", "\\", "|", "/"],
            Self::Off => &["*"],
        }
    }
}

impl<'de> Deserialize<'de> for TuiSpinnerStyle {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Ok(Self::parse(&value).unwrap_or_else(|| {
            tracing::warn!(
                configured = value,
                fallback = "braille",
                "invalid repl.tui.spinner_style; falling back to braille"
            );
            Self::Braille
        }))
    }
}

fn deserialize_tui_spinner_style<'de, D>(deserializer: D) -> Result<TuiSpinnerStyle, D::Error>
where
    D: serde::Deserializer<'de>,
{
    TuiSpinnerStyle::deserialize(deserializer)
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct OperatorUxConfig {
    pub activity: ActivityConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct ActivityConfig {
    pub stuck_notice_after_s: u64,
    pub long_tool_notice_after_s: u64,
    pub show_activity_breadcrumbs: bool,
}

impl Default for ActivityConfig {
    fn default() -> Self {
        Self {
            stuck_notice_after_s: 30,
            long_tool_notice_after_s: 20,
            show_activity_breadcrumbs: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct StatusLineConfig {
    pub enabled: bool,
    pub items: Vec<StatusLineItem>,
}

impl Default for StatusLineConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            items: StatusLineItem::default_items(),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StatusLineItem {
    Model,
    Context,
    Tokens,
    Cost,
    Memory,
    Intent,
    Skills,
    Inbox,
    Channel,
    Trace,
}

impl StatusLineItem {
    pub const CATALOG: [Self; 10] = [
        Self::Model,
        Self::Context,
        Self::Tokens,
        Self::Cost,
        Self::Memory,
        Self::Intent,
        Self::Skills,
        Self::Inbox,
        Self::Channel,
        Self::Trace,
    ];

    pub fn default_items() -> Vec<Self> {
        Self::CATALOG.to_vec()
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Model => "model",
            Self::Context => "context",
            Self::Tokens => "tokens",
            Self::Cost => "cost",
            Self::Memory => "memory",
            Self::Intent => "intent",
            Self::Skills => "skills",
            Self::Inbox => "inbox",
            Self::Channel => "channel",
            Self::Trace => "trace",
        }
    }
}

impl Default for ChannelsConfig {
    fn default() -> Self {
        Self {
            approval_timeout_s: 3600,
            approval_inbox_retention_days: 30,
            telegram: TelegramChannelConfig::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct TelegramChannelConfig {
    pub enabled: bool,
    pub min_interval_ms_per_chat: u64,
    pub min_interval_ms_global: u64,
}

impl Default for TelegramChannelConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            min_interval_ms_per_chat: 1200,
            min_interval_ms_global: 40,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct JobsConfig {
    pub enabled: bool,
    pub max_concurrent_runs: usize,
    pub default_timeout_s: u64,
    pub default_timezone: Option<String>,
}

impl Default for JobsConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            max_concurrent_runs: 1,
            default_timeout_s: 600,
            default_timezone: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct InstallConfig {
    pub remember_approvals: bool,
}

impl Default for InstallConfig {
    fn default() -> Self {
        Self {
            remember_approvals: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct IntentClassifierConfig {
    pub enabled: bool,
    pub model: String,
    pub rule_only: bool,
    pub per_turn_token_budget: u32,
}

impl Default for IntentClassifierConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            model: String::new(),
            rule_only: false,
            per_turn_token_budget: 2000,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct MemoryConfig {
    pub prefetch_enabled: bool,
    pub prefetch_default_limit: usize,
    pub refresh_after_external_evidence: bool,
    pub max_refreshes_per_turn: u32,
    pub max_synopsis_bytes: usize,
    pub max_memory_md_head_bytes: usize,
    pub max_daily_head_bytes: usize,
    pub max_daily_tail_bytes: usize,
    pub max_ephemeral_summary_bytes: usize,
    pub max_prefetch_snippets: usize,
    pub max_prefetch_snippet_bytes: usize,
    pub max_ephemeral_bytes: usize,
    pub max_staged_entries_per_turn: usize,
    pub max_subagent_snippets: usize,
    pub staged_entry_ttl_days: u16,
    pub staged_total_cap: usize,
    pub rejected_retention_days: u16,
    pub trash_retention_days: u16,
    pub index_auto_rebuild: bool,
    pub default_search_limit: usize,
    pub default_daily_recency_days: u16,
    pub max_journal_tool_output_bytes: usize,
    pub surface_staged_on_turn_end: bool,
    pub routing: MemoryRoutingConfig,
    pub episodes: MemoryEpisodesConfig,
    pub facts: MemoryFactsConfig,
    pub semantic: MemorySemanticConfig,
}

impl Default for MemoryConfig {
    fn default() -> Self {
        Self {
            prefetch_enabled: true,
            prefetch_default_limit: 5,
            refresh_after_external_evidence: true,
            max_refreshes_per_turn: 1,
            max_synopsis_bytes: 8 * 1024,
            max_memory_md_head_bytes: 2 * 1024,
            max_daily_head_bytes: 2 * 1024,
            max_daily_tail_bytes: 1024,
            max_ephemeral_summary_bytes: 2 * 1024,
            max_prefetch_snippets: 5,
            max_prefetch_snippet_bytes: 512,
            max_ephemeral_bytes: 32 * 1024,
            max_staged_entries_per_turn: 5,
            max_subagent_snippets: 3,
            staged_entry_ttl_days: 90,
            staged_total_cap: 500,
            rejected_retention_days: 30,
            trash_retention_days: 30,
            index_auto_rebuild: true,
            default_search_limit: 10,
            default_daily_recency_days: 2,
            max_journal_tool_output_bytes: 4 * 1024,
            surface_staged_on_turn_end: true,
            routing: MemoryRoutingConfig::default(),
            episodes: MemoryEpisodesConfig::default(),
            facts: MemoryFactsConfig::default(),
            semantic: MemorySemanticConfig::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct MemoryRoutingConfig {
    pub mode: MemoryRoutingMode,
    pub always_eligible_skills: Vec<String>,
    pub auto_activate_intents: Vec<String>,
    pub auto_activate_cues: Vec<String>,
}

impl Default for MemoryRoutingConfig {
    fn default() -> Self {
        Self {
            mode: MemoryRoutingMode::AlwaysEligible,
            always_eligible_skills: vec!["memory-curator".into()],
            auto_activate_intents: vec![Intent::MemoryQuery.as_str().into()],
            auto_activate_cues: vec![
                "remember".into(),
                "recall".into(),
                "what do you remember".into(),
                "review staged".into(),
                "promote that".into(),
                "forget".into(),
            ],
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MemoryRoutingMode {
    AlwaysEligible,
}

impl MemoryRoutingMode {
    pub fn label(self) -> &'static str {
        match self {
            Self::AlwaysEligible => "always_eligible",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct MemoryEpisodesConfig {
    pub enabled: bool,
    pub prefetch_enabled: bool,
    pub episode_lookback_days: u16,
    pub max_episode_summaries: usize,
    pub max_episode_hits: usize,
}

impl Default for MemoryEpisodesConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            prefetch_enabled: false,
            episode_lookback_days: 30,
            max_episode_summaries: 10,
            max_episode_hits: 5,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct MemoryFactsConfig {
    pub enabled: bool,
    pub max_facts_per_entry: usize,
}

impl Default for MemoryFactsConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            max_facts_per_entry: 12,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct MemorySemanticConfig {
    pub enabled: bool,
    pub provider: String,
    pub embedding_model: String,
    pub hybrid_weight: f64,
}

impl Default for MemorySemanticConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            provider: "none".into(),
            embedding_model: String::new(),
            hybrid_weight: 0.35,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct LearningConfig {
    pub enabled: bool,
    pub personality_digest: PersonalityDigestConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct PersonalityDigestConfig {
    pub enabled: bool,
    pub schedule: String,
    pub output_path: String,
    pub include_tiers: Vec<String>,
    pub include_episodes: bool,
    pub episode_lookback_days: u16,
    pub max_episode_summaries: usize,
    pub max_input_bytes: usize,
    pub max_output_bytes: usize,
}

impl Default for PersonalityDigestConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            schedule: "@weekly on sunday at 18:00".into(),
            output_path: "PERSONALITY.md".into(),
            include_tiers: vec!["durable".into(), "fact".into()],
            include_episodes: true,
            episode_lookback_days: 30,
            max_episode_summaries: 10,
            max_input_bytes: 24 * 1024,
            max_output_bytes: 4 * 1024,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct SelfImprovementConfig {
    #[serde(
        default,
        deserialize_with = "deserialize_optional_pathbuf",
        serialize_with = "serialize_optional_pathbuf"
    )]
    pub source_checkout: Option<PathBuf>,
    pub worktree_root: PathBuf,
    pub max_worktree_gb: u32,
    pub install_mode: SelfImprovementInstallMode,
    pub keep_rejected_worktree: bool,
}

impl Default for SelfImprovementConfig {
    fn default() -> Self {
        Self {
            source_checkout: None,
            worktree_root: PathBuf::from("~/.allbert/worktrees"),
            max_worktree_gb: 10,
            install_mode: SelfImprovementInstallMode::ApplyToCurrentBranch,
            keep_rejected_worktree: false,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum SelfImprovementInstallMode {
    ApplyToCurrentBranch,
}

impl SelfImprovementInstallMode {
    pub fn label(self) -> &'static str {
        match self {
            Self::ApplyToCurrentBranch => "apply-to-current-branch",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ScriptingConfig {
    #[serde(default)]
    pub engine: ScriptingEngineConfig,
    #[serde(default)]
    pub max_execution_ms: u32,
    #[serde(default)]
    pub max_memory_kb: u32,
    #[serde(default)]
    pub max_output_bytes: u32,
    #[serde(default)]
    pub allow_stdlib: Vec<String>,
    #[serde(default = "default_lua_deny_stdlib")]
    pub deny_stdlib: Vec<String>,
}

impl Default for ScriptingConfig {
    fn default() -> Self {
        Self {
            engine: ScriptingEngineConfig::Disabled,
            max_execution_ms: 1000,
            max_memory_kb: 64 * 1024,
            max_output_bytes: 1024 * 1024,
            allow_stdlib: vec!["string".into(), "math".into(), "table".into()],
            deny_stdlib: default_lua_deny_stdlib(),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ScriptingEngineConfig {
    #[default]
    Disabled,
    Lua,
}

impl ScriptingEngineConfig {
    pub fn label(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Lua => "lua",
        }
    }
}

fn default_lua_deny_stdlib() -> Vec<String> {
    vec![
        "io".into(),
        "os".into(),
        "package".into(),
        "require".into(),
        "debug".into(),
        "coroutine".into(),
    ]
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityConfig {
    #[serde(default)]
    pub exec_allow: Vec<String>,
    #[serde(default)]
    pub exec_deny: Vec<String>,
    #[serde(default)]
    pub fs_roots: Vec<PathBuf>,
    #[serde(default)]
    pub web: WebSecurityConfig,
    #[serde(default)]
    pub auto_confirm: bool,
}

impl Default for SecurityConfig {
    fn default() -> Self {
        Self {
            exec_allow: default_exec_allow(),
            exec_deny: default_exec_deny(),
            fs_roots: Vec::new(),
            web: WebSecurityConfig::default(),
            auto_confirm: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebSecurityConfig {
    #[serde(default)]
    pub allow_hosts: Vec<String>,
    #[serde(default)]
    pub deny_hosts: Vec<String>,
    #[serde(default = "default_web_timeout_s")]
    pub timeout_s: u64,
}

impl Default for WebSecurityConfig {
    fn default() -> Self {
        Self {
            allow_hosts: Vec::new(),
            deny_hosts: Vec::new(),
            timeout_s: default_web_timeout_s(),
        }
    }
}

fn default_exec_allow() -> Vec<String> {
    vec!["bash".into(), "python".into()]
}

fn default_web_timeout_s() -> u64 {
    15
}

fn default_exec_deny() -> Vec<String> {
    vec![
        "sh".into(),
        "zsh".into(),
        "fish".into(),
        "ruby".into(),
        "perl".into(),
    ]
}

fn legacy_v0_3_exec_deny() -> Vec<String> {
    vec![
        "sh".into(),
        "bash".into(),
        "zsh".into(),
        "fish".into(),
        "python".into(),
        "python3".into(),
        "node".into(),
        "ruby".into(),
        "perl".into(),
    ]
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct LimitsConfig {
    pub daily_usd_cap: Option<f64>,
    pub max_turn_usd: f64,
    pub max_turn_s: u64,
    pub max_turns: u32,
    pub max_tool_calls_per_turn: u32,
    pub max_tool_output_bytes_per_call: usize,
    pub max_tool_output_bytes_total: usize,
    pub max_bootstrap_file_bytes: usize,
    pub max_prompt_bootstrap_bytes: usize,
    pub max_prompt_memory_bytes: usize,
    pub max_skill_args_bytes: usize,
}

impl Default for LimitsConfig {
    fn default() -> Self {
        Self {
            daily_usd_cap: None,
            max_turn_usd: 0.50,
            max_turn_s: 120,
            max_turns: 8,
            max_tool_calls_per_turn: 16,
            max_tool_output_bytes_per_call: 8 * 1024,
            max_tool_output_bytes_total: 64 * 1024,
            max_bootstrap_file_bytes: 2 * 1024,
            max_prompt_bootstrap_bytes: 6 * 1024,
            max_prompt_memory_bytes: 4 * 1024,
            max_skill_args_bytes: 2 * 1024,
        }
    }
}

impl Config {
    pub fn default_template() -> Self {
        Self {
            model: ModelConfig {
                provider: Provider::Ollama,
                model_id: "gemma4".into(),
                api_key_env: None,
                base_url: Some("http://127.0.0.1:11434".into()),
                max_tokens: 4096,
                context_window_tokens: 0,
            },
            setup: SetupConfig::default(),
            daemon: DaemonConfig::default(),
            sessions: SessionsConfig::default(),
            channels: ChannelsConfig::default(),
            repl: ReplConfig::default(),
            operator_ux: OperatorUxConfig::default(),
            jobs: JobsConfig::default(),
            install: InstallConfig::default(),
            intent_classifier: IntentClassifierConfig::default(),
            memory: MemoryConfig::default(),
            learning: LearningConfig::default(),
            self_improvement: SelfImprovementConfig::default(),
            scripting: ScriptingConfig::default(),
            security: SecurityConfig::default(),
            limits: LimitsConfig::default(),
            trace: false,
        }
    }

    pub fn load_or_create(paths: &AllbertPaths) -> Result<Self, KernelError> {
        paths.ensure()?;
        if paths.config.exists() {
            let raw = std::fs::read_to_string(&paths.config)
                .map_err(|e| KernelError::InitFailed(format!("read config: {e}")))?;
            let raw_had_repl_ui = raw_has_repl_ui(&raw);
            let mut parsed: Config = toml::from_str(&raw).map_err(|source| ConfigError::Parse {
                path: paths.config.clone(),
                source,
            })?;
            let migrated = parsed.migrate_loaded_config(raw_had_repl_ui);
            let scripting_normalized = parsed.normalize_scripting_config();
            let operator_ux_normalized = parsed.normalize_operator_ux_config();
            let normalized = scripting_normalized || operator_ux_normalized;
            if migrated || normalized {
                parsed.persist(paths)?;
            }
            parsed
                .validate()
                .map_err(|e| KernelError::InitFailed(format!("invalid config: {e}")))?;
            Ok(parsed)
        } else {
            let template = Self::default_template();
            template.persist(paths)?;
            Ok(template)
        }
    }

    pub fn persist(&self, paths: &AllbertPaths) -> Result<(), KernelError> {
        let rendered = toml::to_string_pretty(self).map_err(ConfigError::from)?;
        atomic_write(&paths.config, rendered.as_bytes()).map_err(|source| ConfigError::Write {
            path: paths.config.clone(),
            source,
        })?;
        Ok(())
    }

    fn migrate_loaded_config(&mut self, raw_had_repl_ui: bool) -> bool {
        let mut changed = false;
        if self.setup.version == 1 {
            self.setup.version = 2;
            changed = true;
        }
        if self.setup.version == 2
            && self.security.exec_allow.is_empty()
            && self.security.exec_deny == legacy_v0_3_exec_deny()
        {
            self.security.exec_allow = default_exec_allow();
            self.security.exec_deny = default_exec_deny();
            self.setup.version = 3;
            changed = true;
        }
        if self.setup.version == 0 {
            if !raw_had_repl_ui {
                self.repl.ui = ReplUiMode::Classic;
                changed = true;
            }
        } else if self.setup.version < CURRENT_SETUP_VERSION {
            if !raw_had_repl_ui {
                self.repl.ui = ReplUiMode::Classic;
            }
            self.setup.version = CURRENT_SETUP_VERSION;
            changed = true;
        }
        changed
    }

    fn normalize_scripting_config(&mut self) -> bool {
        let mut changed = false;
        if self.scripting.max_execution_ms > LUA_MAX_EXECUTION_MS_CEILING {
            tracing::warn!(
                configured = self.scripting.max_execution_ms,
                ceiling = LUA_MAX_EXECUTION_MS_CEILING,
                "clamping scripting.max_execution_ms to hard ceiling"
            );
            self.scripting.max_execution_ms = LUA_MAX_EXECUTION_MS_CEILING;
            changed = true;
        }
        if self.scripting.max_memory_kb > LUA_MAX_MEMORY_KB_CEILING {
            tracing::warn!(
                configured = self.scripting.max_memory_kb,
                ceiling = LUA_MAX_MEMORY_KB_CEILING,
                "clamping scripting.max_memory_kb to hard ceiling"
            );
            self.scripting.max_memory_kb = LUA_MAX_MEMORY_KB_CEILING;
            changed = true;
        }
        if self.scripting.max_output_bytes > LUA_MAX_OUTPUT_BYTES_CEILING {
            tracing::warn!(
                configured = self.scripting.max_output_bytes,
                ceiling = LUA_MAX_OUTPUT_BYTES_CEILING,
                "clamping scripting.max_output_bytes to hard ceiling"
            );
            self.scripting.max_output_bytes = LUA_MAX_OUTPUT_BYTES_CEILING;
            changed = true;
        }

        let deny = self
            .scripting
            .deny_stdlib
            .iter()
            .map(|value| value.trim().to_ascii_lowercase())
            .collect::<std::collections::HashSet<_>>();
        let before = self.scripting.allow_stdlib.len();
        self.scripting.allow_stdlib.retain(|value| {
            let denied = deny.contains(&value.trim().to_ascii_lowercase());
            if denied {
                tracing::warn!(
                    stdlib = value,
                    "dropping denied Lua stdlib from scripting.allow_stdlib"
                );
            }
            !denied
        });
        changed || self.scripting.allow_stdlib.len() != before
    }

    fn normalize_operator_ux_config(&mut self) -> bool {
        let mut changed = false;
        if self.repl.tui.tick_ms < 40 {
            tracing::warn!(
                configured = self.repl.tui.tick_ms,
                floor = 40,
                "clamping repl.tui.tick_ms to supported floor"
            );
            self.repl.tui.tick_ms = 40;
            changed = true;
        } else if self.repl.tui.tick_ms > 250 {
            tracing::warn!(
                configured = self.repl.tui.tick_ms,
                ceiling = 250,
                "clamping repl.tui.tick_ms to supported ceiling"
            );
            self.repl.tui.tick_ms = 250;
            changed = true;
        }

        let activity = &mut self.operator_ux.activity;
        if activity.stuck_notice_after_s < 5 {
            tracing::warn!(
                configured = activity.stuck_notice_after_s,
                floor = 5,
                "clamping operator_ux.activity.stuck_notice_after_s to supported floor"
            );
            activity.stuck_notice_after_s = 5;
            changed = true;
        } else if activity.stuck_notice_after_s > 600 {
            tracing::warn!(
                configured = activity.stuck_notice_after_s,
                ceiling = 600,
                "clamping operator_ux.activity.stuck_notice_after_s to supported ceiling"
            );
            activity.stuck_notice_after_s = 600;
            changed = true;
        }
        if activity.long_tool_notice_after_s < 5 {
            tracing::warn!(
                configured = activity.long_tool_notice_after_s,
                floor = 5,
                "clamping operator_ux.activity.long_tool_notice_after_s to supported floor"
            );
            activity.long_tool_notice_after_s = 5;
            changed = true;
        } else if activity.long_tool_notice_after_s > 600 {
            tracing::warn!(
                configured = activity.long_tool_notice_after_s,
                ceiling = 600,
                "clamping operator_ux.activity.long_tool_notice_after_s to supported ceiling"
            );
            activity.long_tool_notice_after_s = 600;
            changed = true;
        }
        changed
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.repl.tui.max_transcript_events == 0 {
            return Err("repl.tui.max_transcript_events must be >= 1".into());
        }
        if !(40..=250).contains(&self.repl.tui.tick_ms) {
            return Err("repl.tui.tick_ms must be between 40 and 250".into());
        }
        if self.repl.tui.status_line.enabled && self.repl.tui.status_line.items.is_empty() {
            return Err("repl.tui.status_line.items must not be empty when enabled".into());
        }
        if !(5..=600).contains(&self.operator_ux.activity.stuck_notice_after_s) {
            return Err(
                "operator_ux.activity.stuck_notice_after_s must be between 5 and 600".into(),
            );
        }
        if !(5..=600).contains(&self.operator_ux.activity.long_tool_notice_after_s) {
            return Err(
                "operator_ux.activity.long_tool_notice_after_s must be between 5 and 600".into(),
            );
        }
        if self.memory.prefetch_default_limit == 0 {
            return Err("memory.prefetch_default_limit must be > 0".into());
        }
        if self.memory.default_search_limit == 0 {
            return Err("memory.default_search_limit must be > 0".into());
        }
        if self.memory.max_synopsis_bytes < self.memory.max_ephemeral_summary_bytes {
            return Err(
                "memory.max_synopsis_bytes must be >= memory.max_ephemeral_summary_bytes".into(),
            );
        }
        for intent in &self.memory.routing.auto_activate_intents {
            if Intent::parse(intent).is_none() {
                return Err(format!(
                    "memory.routing.auto_activate_intents contains unknown intent `{intent}`"
                ));
            }
        }
        if self.memory.routing.always_eligible_skills.is_empty() {
            return Err("memory.routing.always_eligible_skills must not be empty".into());
        }
        if self.memory.episodes.max_episode_summaries == 0 {
            return Err("memory.episodes.max_episode_summaries must be > 0".into());
        }
        if self.memory.episodes.max_episode_hits == 0 {
            return Err("memory.episodes.max_episode_hits must be > 0".into());
        }
        if self.memory.facts.max_facts_per_entry == 0 {
            return Err("memory.facts.max_facts_per_entry must be > 0".into());
        }
        if !(0.0..=1.0).contains(&self.memory.semantic.hybrid_weight) {
            return Err("memory.semantic.hybrid_weight must be between 0 and 1".into());
        }
        validate_personality_digest_config(&self.learning.personality_digest)?;
        validate_self_improvement_config(&self.self_improvement)?;
        validate_scripting_config(&self.scripting)?;
        if matches!(self.limits.daily_usd_cap, Some(value) if value < 0.0) {
            return Err("limits.daily_usd_cap must be >= 0".into());
        }
        if self.limits.max_turn_usd < 0.0 {
            return Err("limits.max_turn_usd must be >= 0".into());
        }
        if self.limits.max_turn_s == 0 {
            return Err("limits.max_turn_s must be >= 1".into());
        }
        if self.channels.approval_timeout_s == 0 {
            return Err("channels.approval_timeout_s must be >= 1".into());
        }
        if self.channels.approval_inbox_retention_days == 0 {
            return Err("channels.approval_inbox_retention_days must be >= 1".into());
        }
        if self.channels.telegram.min_interval_ms_per_chat == 0 {
            return Err("channels.telegram.min_interval_ms_per_chat must be >= 1".into());
        }
        if self.channels.telegram.min_interval_ms_global == 0 {
            return Err("channels.telegram.min_interval_ms_global must be >= 1".into());
        }
        Ok(())
    }
}

pub fn write_last_good_config(paths: &AllbertPaths) -> Result<(), KernelError> {
    paths.ensure()?;
    let bytes = std::fs::read(&paths.config)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", paths.config.display())))?;
    atomic_write(&paths.config_last_good, &bytes).map_err(|source| ConfigError::Write {
        path: paths.config_last_good.clone(),
        source,
    })?;
    Ok(())
}

pub fn restore_last_good_config(paths: &AllbertPaths) -> Result<PathBuf, KernelError> {
    paths.ensure()?;
    if !paths.config_last_good.exists() {
        return Err(KernelError::InitFailed(format!(
            "last-good config snapshot not found at {}",
            paths.config_last_good.display()
        )));
    }
    if !paths.config.exists() {
        return Err(KernelError::InitFailed(format!(
            "current config not found at {}; refusing to restore without a broken config to preserve",
            paths.config.display()
        )));
    }

    let stamp = time::OffsetDateTime::now_utc().unix_timestamp();
    let backup = paths.root.join(format!("config.toml.broken-{stamp}"));
    let current = std::fs::read(&paths.config)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", paths.config.display())))?;
    atomic_write(&backup, &current).map_err(|source| ConfigError::Write {
        path: backup.clone(),
        source,
    })?;
    let last_good = std::fs::read(&paths.config_last_good).map_err(|e| {
        KernelError::InitFailed(format!("read {}: {e}", paths.config_last_good.display()))
    })?;
    atomic_write(&paths.config, &last_good).map_err(|source| ConfigError::Write {
        path: paths.config.clone(),
        source,
    })?;
    Ok(backup)
}

fn atomic_write(path: &std::path::Path, bytes: &[u8]) -> Result<(), std::io::Error> {
    crate::atomic_write(path, bytes)
}

fn deserialize_optional_pathbuf<'de, D>(deserializer: D) -> Result<Option<PathBuf>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<String>::deserialize(deserializer)?;
    Ok(value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from))
}

fn serialize_optional_pathbuf<S>(value: &Option<PathBuf>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    let rendered = value
        .as_ref()
        .map(|path| path.display().to_string())
        .unwrap_or_default();
    serializer.serialize_str(&rendered)
}

fn validate_self_improvement_config(config: &SelfImprovementConfig) -> Result<(), String> {
    if config.worktree_root.as_os_str().is_empty() {
        return Err("self_improvement.worktree_root must not be empty".into());
    }
    if config.max_worktree_gb == 0 {
        return Err("self_improvement.max_worktree_gb must be >= 1".into());
    }
    Ok(())
}

fn validate_scripting_config(config: &ScriptingConfig) -> Result<(), String> {
    if config.max_execution_ms == 0 {
        return Err("scripting.max_execution_ms must be >= 1".into());
    }
    if config.max_memory_kb == 0 {
        return Err("scripting.max_memory_kb must be >= 1".into());
    }
    if config.max_output_bytes == 0 {
        return Err("scripting.max_output_bytes must be >= 1".into());
    }
    Ok(())
}

fn validate_personality_digest_config(config: &PersonalityDigestConfig) -> Result<(), String> {
    let output = config.output_path.trim();
    if output.is_empty() {
        return Err("learning.personality_digest.output_path must not be empty".into());
    }
    let path = std::path::Path::new(output);
    if path.is_absolute() {
        return Err(
            "learning.personality_digest.output_path must be relative to ALLBERT_HOME".into(),
        );
    }
    if path.components().any(|component| {
        matches!(
            component,
            std::path::Component::ParentDir
                | std::path::Component::RootDir
                | std::path::Component::Prefix(_)
        )
    }) {
        return Err("learning.personality_digest.output_path must stay inside ALLBERT_HOME".into());
    }
    if path.extension().and_then(|value| value.to_str()) != Some("md") {
        return Err("learning.personality_digest.output_path must be a markdown file".into());
    }
    let normalized = output.replace('\\', "/");
    let reserved_files = [
        "SOUL.md",
        "USER.md",
        "IDENTITY.md",
        "TOOLS.md",
        "AGENTS.md",
        "HEARTBEAT.md",
        "BOOTSTRAP.md",
        "config.toml",
    ];
    if reserved_files
        .iter()
        .any(|reserved| normalized.eq_ignore_ascii_case(reserved))
    {
        return Err(format!(
            "learning.personality_digest.output_path cannot target reserved bootstrap/runtime file {normalized}"
        ));
    }
    for reserved_prefix in [
        "secrets/",
        "run/",
        "logs/",
        "traces/",
        "memory/",
        "jobs/",
        "skills/",
        "sessions/",
    ] {
        if normalized.starts_with(reserved_prefix) {
            return Err(format!(
                "learning.personality_digest.output_path cannot target reserved runtime path {reserved_prefix}"
            ));
        }
    }
    for tier in &config.include_tiers {
        match tier.trim() {
            "durable" | "fact" | "episode" => {}
            other => {
                return Err(format!(
                    "learning.personality_digest.include_tiers contains unsupported tier `{other}`"
                ))
            }
        }
    }
    if config.max_episode_summaries == 0 {
        return Err("learning.personality_digest.max_episode_summaries must be > 0".into());
    }
    if config.max_input_bytes < 1024 {
        return Err("learning.personality_digest.max_input_bytes must be >= 1024".into());
    }
    if config.max_output_bytes < 512 {
        return Err("learning.personality_digest.max_output_bytes must be >= 512".into());
    }
    Ok(())
}

fn raw_has_repl_ui(raw: &str) -> bool {
    match raw.parse::<toml::Value>() {
        Ok(value) => value.get("repl").and_then(|repl| repl.get("ui")).is_some(),
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let unique = format!(
                "allbert-config-test-{}-{}-{}",
                std::process::id(),
                counter,
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("time should be monotonic")
                    .as_nanos()
            );
            let path = std::env::temp_dir().join(unique);
            std::fs::create_dir_all(&path).expect("temp root should be created");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.clone())
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn provider_metadata_covers_v0_10_providers() {
        assert_eq!(Provider::parse("anthropic"), Some(Provider::Anthropic));
        assert_eq!(Provider::parse("openrouter"), Some(Provider::Openrouter));
        assert_eq!(Provider::parse("openai"), Some(Provider::Openai));
        assert_eq!(Provider::parse("gemini"), Some(Provider::Gemini));
        assert_eq!(Provider::parse("ollama"), Some(Provider::Ollama));
        assert_eq!(Provider::Ollama.default_model_id(), "gemma4");
        assert_eq!(Provider::Ollama.default_api_key_env(), None);
        assert_eq!(
            Provider::Ollama.default_base_url(),
            Some("http://127.0.0.1:11434")
        );
        assert!(Provider::Openai.api_key_required());
        assert!(!Provider::Ollama.api_key_required());
        assert_eq!(
            Provider::from_proto_kind(Provider::Gemini.to_proto_kind()),
            Provider::Gemini
        );
    }

    #[test]
    fn model_config_supports_keyless_base_url_providers() {
        let parsed: Config = toml::from_str(
            r#"
[model]
provider = "ollama"
model_id = "gemma4"
base_url = "http://127.0.0.1:11434"
max_tokens = 4096
"#,
        )
        .expect("ollama config should parse without api_key_env");

        assert_eq!(parsed.model.provider, Provider::Ollama);
        assert_eq!(parsed.model.context_window_tokens, 0);
        assert_eq!(parsed.model.api_key_env, None);
        assert_eq!(
            parsed.model.base_url.as_deref(),
            Some("http://127.0.0.1:11434")
        );
    }

    #[test]
    fn fresh_profile_serializes_tui_defaults() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let config = Config::load_or_create(&paths).expect("fresh config should load");

        assert_eq!(config.repl.ui, ReplUiMode::Tui);
        assert_eq!(config.repl.tui.spinner_style, TuiSpinnerStyle::Braille);
        assert_eq!(config.repl.tui.tick_ms, 80);
        assert_eq!(config.operator_ux.activity.stuck_notice_after_s, 30);
        assert_eq!(config.operator_ux.activity.long_tool_notice_after_s, 20);
        assert!(config.operator_ux.activity.show_activity_breadcrumbs);
        assert_eq!(config.model.context_window_tokens, 0);
        assert_eq!(
            config.memory.routing.mode,
            MemoryRoutingMode::AlwaysEligible
        );
        assert_eq!(
            config.memory.routing.auto_activate_intents,
            vec![String::from("memory_query")]
        );

        let rendered = std::fs::read_to_string(&paths.config).expect("config should persist");
        assert!(rendered.contains("ui = \"tui\""));
        assert!(rendered.contains("context_window_tokens = 0"));
        assert!(rendered.contains("mode = \"always_eligible\""));
        assert!(rendered.contains("[self_improvement]"));
        assert!(rendered.contains("source_checkout = \"\""));
        assert!(rendered.contains("worktree_root = \"~/.allbert/worktrees\""));
        assert!(rendered.contains("install_mode = \"apply-to-current-branch\""));
        assert!(rendered.contains("[scripting]"));
        assert!(rendered.contains("engine = \"disabled\""));
        assert!(rendered.contains("max_execution_ms = 1000"));
        assert!(rendered.contains("spinner_style = \"braille\""));
        assert!(rendered.contains("tick_ms = 80"));
        assert!(rendered.contains("[operator_ux.activity]"));
        assert!(rendered.contains("stuck_notice_after_s = 30"));
    }

    #[test]
    fn last_good_config_snapshot_restores_broken_current_config() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let mut config = Config::default_template();
        config.model.model_id = "known-good-model".into();
        config.persist(&paths).expect("config should persist");
        write_last_good_config(&paths).expect("last-good snapshot should write");

        std::fs::write(&paths.config, "not = [valid toml").expect("broken config should write");
        let backup = restore_last_good_config(&paths).expect("last-good should restore");

        let restored = std::fs::read_to_string(&paths.config).expect("config should read");
        assert!(restored.contains("known-good-model"));
        let broken = std::fs::read_to_string(backup).expect("broken backup should read");
        assert_eq!(broken, "not = [valid toml");
    }

    #[test]
    fn tui_spinner_style_parses_and_invalid_falls_back() {
        assert_eq!(TuiSpinnerStyle::parse("dots"), Some(TuiSpinnerStyle::Dots));
        assert_eq!(TuiSpinnerStyle::parse("bar"), Some(TuiSpinnerStyle::Bar));
        assert_eq!(TuiSpinnerStyle::parse("off"), Some(TuiSpinnerStyle::Off));
        assert_eq!(TuiSpinnerStyle::parse("nope"), None);

        let parsed: Config = toml::from_str(
            r#"
[model]
provider = "ollama"
model_id = "gemma4"
max_tokens = 4096

[repl.tui]
spinner_style = "sparkles"
"#,
        )
        .expect("invalid spinner style should fall back at parse time");

        assert_eq!(parsed.repl.tui.spinner_style, TuiSpinnerStyle::Braille);
    }

    #[test]
    fn tui_and_activity_thresholds_clamp_on_load() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should be created");
        std::fs::write(
            &paths.config,
            r#"
[model]
provider = "ollama"
model_id = "gemma4"
max_tokens = 4096

[repl.tui]
tick_ms = 1

[operator_ux.activity]
stuck_notice_after_s = 999
long_tool_notice_after_s = 1
"#,
        )
        .expect("config should be written");

        let config = Config::load_or_create(&paths).expect("config should load with clamps");
        assert_eq!(config.repl.tui.tick_ms, 40);
        assert_eq!(config.operator_ux.activity.stuck_notice_after_s, 600);
        assert_eq!(config.operator_ux.activity.long_tool_notice_after_s, 5);

        let rendered = std::fs::read_to_string(&paths.config).expect("config should persist");
        assert!(rendered.contains("tick_ms = 40"));
        assert!(rendered.contains("stuck_notice_after_s = 600"));
        assert!(rendered.contains("long_tool_notice_after_s = 5"));
    }

    #[test]
    fn legacy_config_without_setup_preserves_setup_needed_and_migrates_classic_ui() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should be created");

        let legacy = r#"
[model]
provider = "anthropic"
model_id = "claude-sonnet-4-5"
api_key_env = "ANTHROPIC_API_KEY"
max_tokens = 4096

[security]
fs_roots = []

[limits]
max_turns = 8
max_tool_calls_per_turn = 16
max_tool_output_bytes_per_call = 8192
max_tool_output_bytes_total = 65536
max_bootstrap_file_bytes = 2048
max_prompt_bootstrap_bytes = 6144
max_prompt_memory_bytes = 4096
max_skill_args_bytes = 2048

trace = false
"#;

        std::fs::write(&paths.config, legacy).expect("legacy config should be written");
        let config = Config::load_or_create(&paths).expect("config should load");
        assert_eq!(config.setup.version, 0);
        assert_eq!(config.repl.ui, ReplUiMode::Classic);

        let rendered = std::fs::read_to_string(&paths.config).expect("config should persist");
        assert!(rendered.contains("ui = \"classic\""));
    }

    #[test]
    fn v0_1_setup_version_migrates_to_current_and_persists_classic_ui() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should be created");

        let legacy = r#"
[model]
provider = "anthropic"
model_id = "claude-sonnet-4-5"
api_key_env = "ANTHROPIC_API_KEY"
max_tokens = 4096

[setup]
version = 1

[security]
fs_roots = []

[limits]
max_turns = 8
max_tool_calls_per_turn = 16
max_tool_output_bytes_per_call = 8192
max_tool_output_bytes_total = 65536
max_bootstrap_file_bytes = 2048
max_prompt_bootstrap_bytes = 6144
max_prompt_memory_bytes = 4096
max_skill_args_bytes = 2048

trace = false
"#;

        std::fs::write(&paths.config, legacy).expect("legacy config should be written");
        let config = Config::load_or_create(&paths).expect("config should load");
        assert_eq!(config.setup.version, CURRENT_SETUP_VERSION);
        assert_eq!(config.repl.ui, ReplUiMode::Classic);
        assert!(config.daemon.auto_spawn);
        assert_eq!(config.channels.approval_timeout_s, 3600);
        assert!(!config.channels.telegram.enabled);
        assert_eq!(config.jobs.max_concurrent_runs, 1);

        let reloaded = Config::load_or_create(&paths).expect("config should reload");
        assert_eq!(reloaded.setup.version, CURRENT_SETUP_VERSION);
        assert_eq!(reloaded.repl.ui, ReplUiMode::Classic);
    }

    #[test]
    fn explicit_legacy_tui_ui_is_preserved() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should be created");

        let legacy = r#"
[model]
provider = "ollama"
model_id = "gemma4"
base_url = "http://127.0.0.1:11434"
max_tokens = 4096

[setup]
version = 1

[repl]
ui = "tui"
"#;

        std::fs::write(&paths.config, legacy).expect("legacy config should be written");
        let config = Config::load_or_create(&paths).expect("config should load");
        assert_eq!(config.setup.version, CURRENT_SETUP_VERSION);
        assert_eq!(config.repl.ui, ReplUiMode::Tui);
    }

    #[test]
    fn invalid_status_line_item_name_fails_to_parse() {
        let err = toml::from_str::<Config>(
            r#"
[model]
provider = "ollama"
model_id = "gemma4"
max_tokens = 4096

[repl.tui.status_line]
items = ["model", "bogus"]
"#,
        )
        .expect_err("unknown status-line item should fail");
        assert!(err.to_string().contains("unknown variant"));
    }

    #[test]
    fn invalid_memory_routing_mode_fails_to_parse() {
        let err = toml::from_str::<Config>(
            r#"
[model]
provider = "ollama"
model_id = "gemma4"
max_tokens = 4096

[memory.routing]
mode = "always_active"
"#,
        )
        .expect_err("unknown routing mode should fail");
        assert!(err.to_string().contains("unknown variant"));
    }

    #[test]
    fn invalid_memory_routing_intent_fails_validation() {
        let mut config = Config::default_template();
        config.memory.routing.auto_activate_intents = vec!["memory_query".into(), "bogus".into()];

        let err = config.validate().expect_err("unknown intent should fail");
        assert!(err.contains("unknown intent `bogus`"));
    }

    #[test]
    fn context_window_zero_means_unknown_and_is_valid() {
        let mut config = Config::default_template();
        config.model.context_window_tokens = 0;
        config.validate().expect("unknown context size is valid");
    }

    #[test]
    fn semantic_hybrid_weight_must_be_unit_interval() {
        let mut config = Config::default_template();
        config.memory.semantic.hybrid_weight = 1.01;
        assert!(config.validate().is_err());

        config.memory.semantic.hybrid_weight = 0.0;
        config.validate().expect("lower bound is valid");

        config.memory.semantic.hybrid_weight = 1.0;
        config.validate().expect("upper bound is valid");
    }

    #[test]
    fn scripting_config_validation_rejects_zero_budgets() {
        let mut config = Config::default_template();
        config.scripting.max_execution_ms = 0;
        let err = config.validate().expect_err("zero budget should fail");
        assert!(err.contains("scripting.max_execution_ms"));

        let mut config = Config::default_template();
        config.scripting.max_memory_kb = 0;
        assert!(config.validate().is_err());

        let mut config = Config::default_template();
        config.scripting.max_output_bytes = 0;
        assert!(config.validate().is_err());
    }

    #[test]
    fn lua_hard_ceiling_clamps_loaded_config() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should be created");
        std::fs::write(
            &paths.config,
            r#"
[model]
provider = "ollama"
model_id = "gemma4"
max_tokens = 4096

[scripting]
engine = "lua"
max_execution_ms = 999999
max_memory_kb = 999999
max_output_bytes = 99999999
allow_stdlib = ["string", "io"]
deny_stdlib = ["io", "os", "package", "require", "debug", "coroutine"]
"#,
        )
        .expect("config should be written");

        let config = Config::load_or_create(&paths).expect("config should load");
        assert_eq!(
            config.scripting.max_execution_ms,
            LUA_MAX_EXECUTION_MS_CEILING
        );
        assert_eq!(config.scripting.max_memory_kb, LUA_MAX_MEMORY_KB_CEILING);
        assert_eq!(
            config.scripting.max_output_bytes,
            LUA_MAX_OUTPUT_BYTES_CEILING
        );
        assert!(!config
            .scripting
            .allow_stdlib
            .iter()
            .any(|item| item == "io"));
    }

    #[test]
    fn learning_personality_digest_rejects_reserved_output_targets() {
        let mut config = Config::default_template();
        config.learning.personality_digest.output_path = "SOUL.md".into();
        let err = config
            .validate()
            .expect_err("digest must not target SOUL.md");
        assert!(err.contains("reserved"));

        let mut config = Config::default_template();
        config.learning.personality_digest.output_path = "memory/PERSONALITY.md".into();
        let err = config
            .validate()
            .expect_err("digest must not target memory runtime paths");
        assert!(err.contains("reserved runtime path"));
    }

    #[test]
    fn rejects_zero_channel_timeouts_or_rate_limits() {
        let mut config = Config::default_template();
        config.channels.approval_timeout_s = 0;
        assert!(config.validate().is_err());

        let mut config = Config::default_template();
        config.channels.telegram.min_interval_ms_per_chat = 0;
        assert!(config.validate().is_err());

        let mut config = Config::default_template();
        config.channels.telegram.min_interval_ms_global = 0;
        assert!(config.validate().is_err());
    }

    #[test]
    fn rejects_invalid_turn_budget_limits() {
        let mut config = Config::default_template();
        config.limits.max_turn_usd = -0.01;
        assert!(config.validate().is_err());

        let mut config = Config::default_template();
        config.limits.max_turn_s = 0;
        assert!(config.validate().is_err());
    }
}
