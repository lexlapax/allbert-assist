# ADR 0069: ScriptingEngine trait with Lua as the v0.12 default embedded runtime

Date: 2026-04-23
Status: Accepted

## Context

Skills that ship `scripts/` directories already run through the kernel exec seam (ADR 0034) — bash, python, node, anything on the `security.exec_allow` list. That covers the "out-of-process script" case well: the kernel spawns a subprocess, hooks observe it, the OS provides isolation, and exit codes carry the result.

What it does not cover is the **in-process embedded runtime** case. There are three real reasons to want one:

1. **Performance for many small calls.** A skill that wants to evaluate dozens of small predicates per turn cannot afford a fork-exec each time.
2. **Tighter sandbox primitives.** A subprocess is an OS-level boundary; an embedded runtime can apply finer-grained limits (instruction count, memory, allowed builtins) that the OS cannot easily express.
3. **Deterministic teardown.** A subprocess has a syscall budget; an embedded runtime can hard-stop on a tick limit and report exactly how much was consumed.

Adding an embedded runtime is also where the kernel risks picking up a heavyweight new dependency. v0.7 already had a moment where "we need scripting" almost meant "let's add a JS engine to the kernel." The lesson then was: pick the seam first, then pick **one** implementation behind it. Otherwise every release adds a new "we also support X" runtime and the policy surface fragments.

The candidate Lua crates were considered:

| Crate | Posture | Sandbox | Outcome |
| --- | --- | --- | --- |
| `mlua` | Actively maintained, sync + async, explicit stdlib selection, instruction-count hooks, and memory hooks | Lua 5.4 stdlib allowlist plus denied globals and caps | **Chosen.** |
| `rlua` | Older, no longer the active fork; many users have migrated to `mlua` | Manual | Rejected. |
| `piccolo` | Pure-Rust Lua, interesting safety story | Limited stdlib parity | Rejected. Too early for v0.12. |
| `hlua` | Unmaintained | Manual | Rejected. |

WebAssembly (e.g. `wasmtime`) was considered as an alternative. It offers excellent isolation but the developer ergonomics for skill-script-shaped use cases (many tiny scripts authored quickly) are weaker, and it pulls a much larger dependency. WASM remains an option for a future engine implementation behind the same seam.

## Decision

v0.12 introduces a `ScriptingEngine` trait in the kernel. The v0.12 default implementation is **Lua via `mlua`**, configured with an explicit Lua 5.4 stdlib allowlist, denied globals, memory limits, and instruction hooks. Both the seam and the implementation are opt-in.

### The trait

In `crates/allbert-kernel/src/scripting/`:

```rust
pub trait ScriptingEngine: Send + Sync {
    /// Stable name used in exec hook tool surface, e.g. "lua".
    fn name(&self) -> &'static str;

    /// Capability flags an installer can inspect before declaring a skill needs this engine.
    fn capabilities(&self) -> ScriptingCapabilities;

    /// Compile / parse the script. `source_ref` is the human-readable origin
    /// (e.g. "skill:foo/scripts/bar.lua") used in errors and hook metadata.
    fn load(&self, source: &str, source_ref: &str) -> Result<LoadedScript>;

    /// Execute a loaded script with serialized inputs. Outputs are serialized.
    /// Must terminate cleanly when budget is exhausted.
    fn invoke(
        &self,
        script: &LoadedScript,
        inputs: serde_json::Value,
        budget: ScriptBudget,
    ) -> Result<ScriptOutcome>;

    /// Reset any per-engine global state (e.g. between sessions).
    fn reset(&self) -> Result<()>;
}

pub struct ScriptingCapabilities {
    pub supports_async: bool,
    pub max_concurrent_scripts: Option<usize>,
}

pub struct ScriptBudget {
    pub max_execution_ms: u32,
    pub max_memory_kb: u32,
    pub max_output_bytes: u32,
}

pub enum ScriptOutcome {
    Ok { result: serde_json::Value, budget_used: BudgetUsed },
    CapExceeded { which: CapKind, budget_used: BudgetUsed },
    Error { message: String, budget_used: BudgetUsed },
}
```

### Inputs and outputs are serde-JSON only

This is the load-bearing trust decision: scripts receive serialized inputs and return serialized outputs. There is no shared Rust reference, no pointer into session state, no direct memory service access from inside a script, and no embedded host tool-call bridge in v0.12. Any data a script needs must be supplied by the caller as JSON; any state-changing follow-up happens after the script returns through the same tool surface every other extension uses.

This resolves the v0.12 pre-implementation question "do embedded scripts share memory with the host session?" — they do not. Anything else is a trust and lifetime minefield (the Lua VM and the Rust borrow checker disagree on what "alive" means).

### Lua engine implementation

`LuaEngine` is the sole `v0.12` implementation. It uses:

- `mlua` with the `lua54` and `vendored` features (no system Lua dep);
- explicit Lua 5.4 stdlib selection and denied-global removal per ADR 0070;
- `mlua`'s `set_memory_limit` for memory caps;
- a per-invocation hook for the execution-time cap (configurable per call via `ScriptBudget`).

### Skill author surface

Lua scripts are declared in `SKILL.md` frontmatter under the same `scripts:` section as any other interpreter (ADR 0034), with interpreter string `lua` and a relative path:

```yaml
scripts:
  - name: score
    interpreter: lua
    path: scripts/score.lua
```

This keeps the skill-author contract uniform: there is no parallel `lua_scripts:` section. Choosing `lua` as the interpreter has the same shape as choosing `python` or `bash`. The only difference is that `lua` requires the embedded engine to be enabled in config (M7/M8 in the v0.12 plan); a skill that declares Lua scripts without the engine enabled loads but cannot run those scripts (matching ADR 0034's behavior for bash/python without the allowlist entry).

### Hook-observability convention

Embedded-script invocations surface as a synthetic tool name in `BeforeTool` / `AfterTool` events:

```
exec.lua:<skill-name>/<script-path>
```

For example: `exec.lua:summarizer/scripts/score.lua`. The metadata payload mirrors the process-exec metadata shape (interpreter, skill, path) plus `budget_used` from `ScriptOutcome`. This is the convention any future embedded engine MUST follow: `exec.<engine-name>:<source-ref>`. Operators can audit and gate embedded-script calls through the same hook surface they already use for tool calls and process-exec.

### What this ADR does NOT decide

- The specific sandbox policy (allowlist, cap defaults, and strict posture) lives in ADR 0070. This ADR establishes the seam and picks the v0.12 implementation; the policy contract any implementation must satisfy is ADR 0070's job.
- Future engines (WASM, QuickJS, Rhai) slot in behind this trait. Adding one is a kernel-internal change plus an `security.exec_allow` opt-in, not a new top-level ADR — provided the implementation satisfies the ADR 0070 sandbox contract.

## Consequences

**Positive**

- One canonical place where embedded scripts enter the kernel, with one canonical hook-observability convention.
- `mlua` is small, well-understood, and has the necessary primitives (stdlib selection, memory limits, instruction hooks) for honest enforcement.
- Skill authors get a single uniform `scripts:` shape; choosing Lua is just another interpreter string.
- Future engines can land behind the same trait without a re-design.

**Negative**

- Adds a new top-level dependency (`mlua` + vendored Lua 5.4). Build time and binary size grow.
- Skill authors who want to write embedded Lua must learn the sandbox limits (ADR 0070); the seam alone is not the full story.

**Neutral**

- The seam exists even if no operator enables Lua. That keeps the kernel ready for the next embedded-runtime case without retrofitting.
- `mlua`'s async support is available but unused in v0.12. v0.12 uses sync-only invocation; async embedded scripts can be added when there is a concrete need.

## References

- [docs/plans/v0.12-self-improvement.md](../plans/v0.12-self-improvement.md)
- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0006](0006-hook-api-is-public-from-day-one.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0052](0052-kernel-native-operations-promote-to-tool-implementations.md)
- [ADR 0070](0070-embedded-script-sandbox-policy.md)
- [mlua crate docs](https://docs.rs/mlua/latest/mlua/)
- [Lua 5.4 reference](https://www.lua.org/manual/5.4/)
