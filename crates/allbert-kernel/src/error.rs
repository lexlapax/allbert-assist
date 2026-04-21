use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum KernelError {
    #[error("initialization failed: {0}")]
    InitFailed(String),
    #[error("config error: {0}")]
    Config(#[from] ConfigError),
    #[error("llm error: {0}")]
    Llm(#[from] LlmError),
    #[error("hook aborted turn: {0}")]
    Hook(String),
    #[error("{0}")]
    Request(String),
    #[error("cost tracking failed: {0}")]
    Cost(String),
    #[error("{0}")]
    CostCap(String),
    #[error("tracing init failed: {0}")]
    Trace(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("failed to parse config at {path}: {source}")]
    Parse {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },
    #[error("failed to write default config at {path}: {source}")]
    Write {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to serialize default config: {0}")]
    Serialize(#[from] toml::ser::Error),
}

#[derive(Debug, thiserror::Error)]
pub enum ToolError {
    #[error("tool not found: {0}")]
    NotFound(String),
    #[error("tool dispatch failed: {0}")]
    Dispatch(String),
}

#[derive(Debug, thiserror::Error)]
pub enum SkillError {
    #[error("skill not found: {0}")]
    NotFound(String),
    #[error("skill load failed: {0}")]
    Load(String),
}

#[derive(Debug, thiserror::Error)]
pub enum LlmError {
    #[error("missing API key in environment variable {0}")]
    MissingApiKeyEnv(String),
    #[error("unsupported provider: {0}")]
    UnsupportedProvider(String),
    #[error("request failed: {0}")]
    Http(String),
    #[error("unexpected provider response: {0}")]
    Response(String),
}
