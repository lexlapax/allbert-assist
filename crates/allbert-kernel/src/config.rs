use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::error::{ConfigError, KernelError};
use crate::paths::AllbertPaths;

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
    pub jobs: JobsConfig,
    #[serde(default)]
    pub install: InstallConfig,
    #[serde(default)]
    pub intent_classifier: IntentClassifierConfig,
    #[serde(default)]
    pub memory: MemoryConfig,
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
    pub show_inbox_on_attach: bool,
}

impl Default for ReplConfig {
    fn default() -> Self {
        Self {
            show_inbox_on_attach: true,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
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
        }
    }
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
                provider: Provider::Anthropic,
                model_id: "claude-sonnet-4-5".into(),
                api_key_env: Some("ANTHROPIC_API_KEY".into()),
                base_url: None,
                max_tokens: 4096,
            },
            setup: SetupConfig::default(),
            daemon: DaemonConfig::default(),
            sessions: SessionsConfig::default(),
            channels: ChannelsConfig::default(),
            repl: ReplConfig::default(),
            jobs: JobsConfig::default(),
            install: InstallConfig::default(),
            intent_classifier: IntentClassifierConfig::default(),
            memory: MemoryConfig::default(),
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
            let mut parsed: Config = toml::from_str(&raw).map_err(|source| ConfigError::Parse {
                path: paths.config.clone(),
                source,
            })?;
            if parsed.migrate_for_v0_2() {
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

    fn migrate_for_v0_2(&mut self) -> bool {
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
        changed
    }

    pub fn validate(&self) -> Result<(), String> {
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

fn atomic_write(path: &std::path::Path, bytes: &[u8]) -> Result<(), std::io::Error> {
    crate::atomic_write(path, bytes)
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
        assert_eq!(parsed.model.api_key_env, None);
        assert_eq!(
            parsed.model.base_url.as_deref(),
            Some("http://127.0.0.1:11434")
        );
    }

    #[test]
    fn missing_setup_field_migrates_to_version_zero() {
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
    }

    #[test]
    fn v0_1_setup_version_migrates_to_two_and_persists() {
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
        assert_eq!(config.setup.version, 2);
        assert!(config.daemon.auto_spawn);
        assert_eq!(config.channels.approval_timeout_s, 3600);
        assert!(!config.channels.telegram.enabled);
        assert_eq!(config.jobs.max_concurrent_runs, 1);

        let reloaded = Config::load_or_create(&paths).expect("config should reload");
        assert_eq!(reloaded.setup.version, 2);
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
