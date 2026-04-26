use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use std::time::{Duration, Instant};

use mlua::{HookTriggers, Lua, LuaOptions, LuaSerdeExt, StdLib, Value as LuaValue, VmState};
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
    #[error("Lua script load failed for {source_ref}: {message}")]
    Load { source_ref: String, message: String },
    #[error("Lua script invocation failed for {source_ref}: {message}")]
    Invoke { source_ref: String, message: String },
    #[error("Lua sandbox setup failed for {source_ref}: {message}")]
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LuaSandboxPolicy {
    pub allow_stdlib: Vec<String>,
    pub deny_stdlib: Vec<String>,
}

impl Default for LuaSandboxPolicy {
    fn default() -> Self {
        Self {
            allow_stdlib: vec!["string".into(), "math".into(), "table".into()],
            deny_stdlib: vec![
                "io".into(),
                "os".into(),
                "package".into(),
                "require".into(),
                "debug".into(),
                "coroutine".into(),
            ],
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct LuaEngine {
    policy: LuaSandboxPolicy,
}

impl LuaEngine {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_policy(policy: LuaSandboxPolicy) -> Self {
        Self { policy }
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
        let lua = create_sandboxed_lua(&self.policy, source_ref)?;
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
        let lua = create_sandboxed_lua(&self.policy, &script.source_ref)?;
        let memory_limit = (budget.max_memory_kb as usize).saturating_mul(1024);
        lua.set_memory_limit(memory_limit)
            .map_err(|err| ScriptingError::Sandbox {
                source_ref: script.source_ref.clone(),
                message: err.to_string(),
            })?;
        let instructions = Arc::new(AtomicU64::new(0));
        install_execution_hook(
            &lua,
            started,
            Duration::from_millis(budget.max_execution_ms as u64),
            Arc::clone(&instructions),
        );

        let outcome = match invoke_lua(&lua, script, inputs) {
            Ok(value) => value,
            Err(err) if is_execution_cap_error(&err) => {
                return Ok(ScriptOutcome::CapExceeded {
                    which: CapKind::ExecutionTime,
                    budget_used: budget_used(&lua, started, &instructions, 0),
                });
            }
            Err(mlua::Error::MemoryError(_)) => {
                return Ok(ScriptOutcome::CapExceeded {
                    which: CapKind::Memory,
                    budget_used: budget_used(&lua, started, &instructions, 0),
                });
            }
            Err(err) => {
                return Ok(ScriptOutcome::Error {
                    message: err.to_string(),
                    budget_used: budget_used(&lua, started, &instructions, 0),
                });
            }
        };
        let mut budget_used = BudgetUsed {
            output_bytes: serialized_len(&outcome),
            ..budget_used(&lua, started, &instructions, 0)
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

fn create_sandboxed_lua(policy: &LuaSandboxPolicy, source_ref: &str) -> ScriptingResult<Lua> {
    let libs = effective_stdlibs(policy);
    let lua =
        Lua::new_with(libs, LuaOptions::default()).map_err(|err| ScriptingError::Sandbox {
            source_ref: source_ref.into(),
            message: err.to_string(),
        })?;
    remove_denied_globals(&lua, policy).map_err(|err| ScriptingError::Sandbox {
        source_ref: source_ref.into(),
        message: err.to_string(),
    })?;
    Ok(lua)
}

fn effective_stdlibs(policy: &LuaSandboxPolicy) -> StdLib {
    let mut libs = StdLib::NONE;
    for name in &policy.allow_stdlib {
        let normalized = name.trim().to_ascii_lowercase();
        if policy
            .deny_stdlib
            .iter()
            .any(|deny| deny.eq_ignore_ascii_case(&normalized))
        {
            continue;
        }
        libs |= match normalized.as_str() {
            "string" => StdLib::STRING,
            "math" => StdLib::MATH,
            "table" => StdLib::TABLE,
            "utf8" => StdLib::UTF8,
            _ => StdLib::NONE,
        };
    }
    libs
}

fn remove_denied_globals(lua: &Lua, policy: &LuaSandboxPolicy) -> mlua::Result<()> {
    let globals = lua.globals();
    for denied in &policy.deny_stdlib {
        globals.set(denied.as_str(), LuaValue::Nil)?;
    }
    // `require` is a global function rather than a library table.
    if policy
        .deny_stdlib
        .iter()
        .any(|deny| deny.eq_ignore_ascii_case("require"))
    {
        globals.set("require", LuaValue::Nil)?;
    }
    Ok(())
}

fn install_execution_hook(
    lua: &Lua,
    started: Instant,
    max_duration: Duration,
    instructions: Arc<AtomicU64>,
) {
    lua.set_hook(
        HookTriggers::new().every_nth_instruction(1_000),
        move |_lua, _debug| {
            instructions.fetch_add(1_000, Ordering::Relaxed);
            if started.elapsed() > max_duration {
                return Err(mlua::Error::RuntimeError(
                    "allbert-script-cap:execution-time".into(),
                ));
            }
            Ok(VmState::Continue)
        },
    );
}

fn budget_used(
    lua: &Lua,
    started: Instant,
    instructions: &Arc<AtomicU64>,
    output_bytes: u64,
) -> BudgetUsed {
    BudgetUsed {
        instructions: instructions.load(Ordering::Relaxed),
        peak_memory_bytes: lua.used_memory() as u64,
        wall_ms: started.elapsed().as_millis().try_into().unwrap_or(u64::MAX),
        output_bytes,
    }
}

fn is_execution_cap_error(err: &mlua::Error) -> bool {
    err.to_string()
        .contains("allbert-script-cap:execution-time")
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

    #[test]
    fn lua_sandbox_denies_filesystem_process_modules_and_coroutines() {
        let engine = LuaEngine::new();
        for (name, source) in [
            (
                "io",
                "return function(_) return io.open('/etc/passwd', 'r') end",
            ),
            (
                "os",
                "return function(_) return os.execute('echo nope') end",
            ),
            ("require", "return function(_) return require('math') end"),
            ("package", "return function(_) return package.path end"),
            ("debug", "return function(_) return debug.getinfo(1) end"),
            (
                "coroutine",
                "return function(_) return coroutine.create(function() end) end",
            ),
        ] {
            let script = engine
                .load(source, &format!("skill:test/scripts/{name}.lua"))
                .expect("script should compile even when globals are denied");
            let outcome = engine
                .invoke(&script, serde_json::json!({}), budget())
                .expect("sandboxed invocation should return an outcome");
            assert!(
                matches!(outcome, ScriptOutcome::Error { .. }),
                "{name} should be unavailable in the sandbox"
            );
        }
    }

    #[test]
    fn lua_execution_cap_reports_cap_exceeded() {
        let engine = LuaEngine::new();
        let script = engine
            .load(
                "return function(_) local x = 0 while true do x = x + 1 end end",
                "skill:test/scripts/loop.lua",
            )
            .expect("script should load");
        let outcome = engine
            .invoke(
                &script,
                serde_json::json!({}),
                ScriptBudget {
                    max_execution_ms: 1,
                    max_memory_kb: 1024,
                    max_output_bytes: 4096,
                },
            )
            .expect("cap exhaustion should be reported, not thrown");
        assert!(matches!(
            outcome,
            ScriptOutcome::CapExceeded {
                which: CapKind::ExecutionTime,
                ..
            }
        ));
    }

    #[test]
    fn lua_output_cap_reports_cap_exceeded() {
        let engine = LuaEngine::new();
        let script = engine
            .load(
                "return function(_) return { text = string.rep('x', 128) } end",
                "skill:test/scripts/output.lua",
            )
            .expect("script should load");
        let outcome = engine
            .invoke(
                &script,
                serde_json::json!({}),
                ScriptBudget {
                    max_execution_ms: 1000,
                    max_memory_kb: 1024,
                    max_output_bytes: 16,
                },
            )
            .expect("output cap should be reported");
        assert!(matches!(
            outcome,
            ScriptOutcome::CapExceeded {
                which: CapKind::OutputBytes,
                ..
            }
        ));
    }

    #[test]
    fn lua_memory_cap_reports_cap_exceeded() {
        let engine = LuaEngine::new();
        let script = engine
            .load(
                "return function(_) local values = {}; for i = 1, 100000 do values[i] = string.rep('x', 1024) end; return values end",
                "skill:test/scripts/memory.lua",
            )
            .expect("script should load");
        let outcome = engine
            .invoke(
                &script,
                serde_json::json!({}),
                ScriptBudget {
                    max_execution_ms: 1000,
                    max_memory_kb: 256,
                    max_output_bytes: 4096,
                },
            )
            .expect("memory cap should be reported");
        assert!(matches!(
            outcome,
            ScriptOutcome::CapExceeded {
                which: CapKind::Memory,
                ..
            }
        ));
    }
}
