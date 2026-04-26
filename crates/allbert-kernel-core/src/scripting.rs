use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const LUA_MAX_EXECUTION_MS_CEILING: u32 = 30_000;
pub const LUA_MAX_MEMORY_KB_CEILING: u32 = 256 * 1024;
pub const LUA_MAX_OUTPUT_BYTES_CEILING: u32 = 16 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScriptingCapabilities {
    pub supports_async: bool,
    pub max_concurrent_scripts: Option<usize>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct ScriptBudget {
    pub max_execution_ms: u32,
    pub max_memory_kb: u32,
    pub max_output_bytes: u32,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct BudgetUsed {
    pub instructions: u64,
    pub peak_memory_bytes: u64,
    pub wall_ms: u64,
    pub output_bytes: u64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum CapKind {
    ExecutionTime,
    Memory,
    OutputBytes,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "status", rename_all = "kebab-case")]
pub enum ScriptOutcome {
    Ok {
        result: serde_json::Value,
        budget_used: BudgetUsed,
    },
    CapExceeded {
        which: CapKind,
        budget_used: BudgetUsed,
    },
    Error {
        message: String,
        budget_used: BudgetUsed,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadedScript {
    pub engine: &'static str,
    pub source: String,
    pub source_ref: String,
}

#[derive(Debug, Error)]
pub enum ScriptingError {
    #[error("script load failed for {source_ref}: {message}")]
    Load { source_ref: String, message: String },
    #[error("script invocation failed for {source_ref}: {message}")]
    Invoke { source_ref: String, message: String },
    #[error("script sandbox setup failed for {source_ref}: {message}")]
    Sandbox { source_ref: String, message: String },
}

pub type ScriptingResult<T> = Result<T, ScriptingError>;

pub trait ScriptingEngine: Send + Sync {
    fn name(&self) -> &'static str;
    fn capabilities(&self) -> ScriptingCapabilities;
    fn load(&self, source: &str, source_ref: &str) -> ScriptingResult<LoadedScript>;
    fn invoke(
        &self,
        script: &LoadedScript,
        inputs: serde_json::Value,
        budget: ScriptBudget,
    ) -> ScriptingResult<ScriptOutcome>;
    fn reset(&self) -> ScriptingResult<()>;
}
