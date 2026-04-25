use std::time::Instant;

use mlua::{Lua, LuaSerdeExt, Value as LuaValue};
use serde::{Deserialize, Serialize};
use thiserror::Error;

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
    #[error("Lua script load failed for {source_ref}: {message}")]
    Load { source_ref: String, message: String },
    #[error("Lua script invocation failed for {source_ref}: {message}")]
    Invoke { source_ref: String, message: String },
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

#[derive(Debug, Default, Clone, Copy)]
pub struct LuaEngine;

impl LuaEngine {
    pub fn new() -> Self {
        Self
    }
}

impl ScriptingEngine for LuaEngine {
    fn name(&self) -> &'static str {
        "lua"
    }

    fn capabilities(&self) -> ScriptingCapabilities {
        ScriptingCapabilities {
            supports_async: false,
            max_concurrent_scripts: Some(1),
        }
    }

    fn load(&self, source: &str, source_ref: &str) -> ScriptingResult<LoadedScript> {
        let lua = Lua::new();
        lua.load(source)
            .set_name(source_ref)
            .into_function()
            .map_err(|err| ScriptingError::Load {
                source_ref: source_ref.into(),
                message: err.to_string(),
            })?;
        Ok(LoadedScript {
            engine: self.name(),
            source: source.into(),
            source_ref: source_ref.into(),
        })
    }

    fn invoke(
        &self,
        script: &LoadedScript,
        inputs: serde_json::Value,
        budget: ScriptBudget,
    ) -> ScriptingResult<ScriptOutcome> {
        let started = Instant::now();
        let lua = Lua::new();
        let outcome = invoke_lua(&lua, script, inputs).map_err(|err| ScriptingError::Invoke {
            source_ref: script.source_ref.clone(),
            message: err.to_string(),
        })?;
        let mut budget_used = BudgetUsed {
            wall_ms: started.elapsed().as_millis().try_into().unwrap_or(u64::MAX),
            output_bytes: serialized_len(&outcome),
            ..BudgetUsed::default()
        };

        if budget.max_output_bytes > 0 && budget_used.output_bytes > budget.max_output_bytes as u64
        {
            budget_used.output_bytes = budget.max_output_bytes as u64;
            return Ok(ScriptOutcome::CapExceeded {
                which: CapKind::OutputBytes,
                budget_used,
            });
        }

        Ok(ScriptOutcome::Ok {
            result: outcome,
            budget_used,
        })
    }

    fn reset(&self) -> ScriptingResult<()> {
        Ok(())
    }
}

fn invoke_lua(
    lua: &Lua,
    script: &LoadedScript,
    inputs: serde_json::Value,
) -> mlua::Result<serde_json::Value> {
    let loaded = lua.load(&script.source).set_name(&script.source_ref);
    let value = loaded.eval::<LuaValue>()?;
    let function = match value {
        LuaValue::Function(function) => function,
        LuaValue::Nil => lua.globals().get::<mlua::Function>("run")?,
        other => {
            return Err(mlua::Error::RuntimeError(format!(
                "expected script to return a function or define global run, got {}",
                other.type_name()
            )))
        }
    };
    let lua_input = lua.to_value(&inputs)?;
    let result = function.call::<LuaValue>(lua_input)?;
    lua.from_value(result)
}

fn serialized_len(value: &serde_json::Value) -> u64 {
    serde_json::to_vec(value)
        .map(|bytes| bytes.len() as u64)
        .unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn budget() -> ScriptBudget {
        ScriptBudget {
            max_execution_ms: 1000,
            max_memory_kb: 1024,
            max_output_bytes: 4096,
        }
    }

    #[test]
    fn scripting_lua_engine_roundtrips_json() {
        let engine = LuaEngine::new();
        let script = engine
            .load(
                r#"
                return function(input)
                  return {
                    greeting = "hello " .. input.name,
                    count = input.count + 1,
                    tags = { "lua", "json" }
                  }
                end
                "#,
                "skill:test/scripts/hello.lua",
            )
            .expect("script should load");

        let outcome = engine
            .invoke(
                &script,
                serde_json::json!({"name":"Allbert","count":2}),
                budget(),
            )
            .expect("script should run");

        let ScriptOutcome::Ok {
            result,
            budget_used,
        } = outcome
        else {
            panic!("expected ok outcome");
        };
        assert_eq!(result["greeting"], "hello Allbert");
        assert_eq!(result["count"], 3);
        assert!(budget_used.output_bytes > 0);
    }

    #[test]
    fn scripting_lua_engine_reports_load_errors() {
        let engine = LuaEngine::new();
        let err = engine
            .load("return function(", "skill:test/scripts/broken.lua")
            .expect_err("invalid Lua should fail");
        assert!(err.to_string().contains("broken.lua"));
    }

    #[test]
    fn scripting_lua_engine_supports_reset_contract() {
        let engine = LuaEngine::new();
        engine.reset().expect("reset is a no-op for M7 Lua");
    }
}
