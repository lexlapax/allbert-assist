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
    pub jobs: JobsConfig,
    #[serde(default)]
    pub install: InstallConfig,
    #[serde(default)]
    pub intent_classifier: IntentClassifierConfig,
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
    pub api_key_env: String,
    pub max_tokens: u32,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Anthropic,
    Openrouter,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct SetupConfig {
    pub version: u8,
}

impl Default for SetupConfig {
    fn default() -> Self {
        Self { version: 0 }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct DaemonConfig {
    pub socket_path: Option<PathBuf>,
    pub log_dir: Option<PathBuf>,
    pub log_retention_days: u16,
    pub auto_spawn: bool,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            socket_path: None,
            log_dir: None,
            log_retention_days: 7,
            auto_spawn: true,
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
                api_key_env: "ANTHROPIC_API_KEY".into(),
                max_tokens: 4096,
            },
            setup: SetupConfig::default(),
            daemon: DaemonConfig::default(),
            jobs: JobsConfig::default(),
            install: InstallConfig::default(),
            intent_classifier: IntentClassifierConfig::default(),
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
            Ok(parsed)
        } else {
            let template = Self::default_template();
            template.persist(paths)?;
            Ok(template)
        }
    }

    pub fn persist(&self, paths: &AllbertPaths) -> Result<(), KernelError> {
        let rendered = toml::to_string_pretty(self).map_err(ConfigError::from)?;
        std::fs::write(&paths.config, rendered).map_err(|source| ConfigError::Write {
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
        assert_eq!(config.jobs.max_concurrent_runs, 1);

        let reloaded = Config::load_or_create(&paths).expect("config should reload");
        assert_eq!(reloaded.setup.version, 2);
    }
}
