use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::error::{ConfigError, KernelError};
use crate::paths::AllbertPaths;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub model: ModelConfig,
    #[serde(default)]
    pub security: SecurityConfig,
    #[serde(default)]
    pub limits: LimitsConfig,
    #[serde(default)]
    pub trace: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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
            exec_allow: Vec::new(),
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

fn default_web_timeout_s() -> u64 {
    15
}

fn default_exec_deny() -> Vec<String> {
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
            let parsed: Config = toml::from_str(&raw).map_err(|source| ConfigError::Parse {
                path: paths.config.clone(),
                source,
            })?;
            Ok(parsed)
        } else {
            let template = Self::default_template();
            let rendered = toml::to_string_pretty(&template).map_err(ConfigError::from)?;
            std::fs::write(&paths.config, rendered).map_err(|source| ConfigError::Write {
                path: paths.config.clone(),
                source,
            })?;
            Ok(template)
        }
    }
}
