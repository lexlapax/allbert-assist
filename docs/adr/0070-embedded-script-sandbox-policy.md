# ADR 0070: Embedded-script sandbox policy

Date: 2026-04-23
Status: Accepted

## Context

ADR 0069 establishes the `ScriptingEngine` trait and picks `mlua` as the v0.12 embedded Lua runtime. That is the seam, not the policy. The policy question — what an embedded script is and is not allowed to do — needs its own decision because:

- An embedded script runs **in-process**. A subprocess that misbehaves can be SIGKILL'd; a Lua coroutine that escapes the sandbox can leak memory, corrupt host state, or panic the daemon.
- The host kernel cares about three independent caps: execution time (a script that loops forever), memory (a script that allocates without bound), and output size (a script that returns a 1 GB string). All three must terminate the script cleanly without taking down the host.
- Lua's standard library spans benign functional helpers (`string`, `math`, `table`) and direct OS access (`io`, `os`, `package`, `require`). Allowing the latter by default would defeat the entire point of the sandbox.

The sandbox policy is also the one place where "we ship a default" matters most. v0.12 ships exactly one engine, but the policy contract here is what a future engine (WASM, QuickJS, Rhai) MUST satisfy to be a drop-in. So this ADR is two things at once: the policy for the Lua implementation, and the policy contract any future implementation behind ADR 0069's trait must meet.

## Decision

v0.12 introduces a sandbox policy for embedded scripts with three components: a stdlib allowlist, three independent budget caps, and a config schema that makes both visible and tunable.

### Stdlib allowlist (Lua specifics)

The `mlua` engine uses Lua 5.4 with explicit standard-library selection and denied-global removal. The selected `lua54` backend does not expose the Luau-only sandbox helper, so v0.12 enforces the sandbox contract directly:

| Library | Default | Rationale |
| --- | --- | --- |
| `string` | ✅ allow | Benign string manipulation. |
| `math` | ✅ allow | Pure arithmetic. |
| `table` | ✅ allow | Pure data structure. |
| `io` | ❌ deny | Direct filesystem. |
| `os` | ❌ deny | OS access (`os.execute`, `os.getenv`). |
| `package` | ❌ deny | Module loading; can pull arbitrary code. |
| `require` | ❌ deny | Same. |
| `debug` | ❌ deny | Allows poking host state. |
| `coroutine` | ❌ deny by default | Coroutines complicate budget accounting; can be allowed in future modes. |

Other engines (WASM, QuickJS) MUST express an equivalent allow/deny posture for their host APIs. The contract is: by default, no filesystem, no network, no process spawning, no module loading, no host-state introspection.

### Budget caps

Three caps, all enforced by the engine, all reported in `BudgetUsed` per ADR 0069:

| Cap | Default | Mechanism |
| --- | --- | --- |
| `max_execution_ms` | `1000` | `mlua` instruction-count hook plus wall-clock check; configurable per invocation up to a hard kernel ceiling. |
| `max_memory_kb` | `65536` (64 MB) | `mlua::Lua::set_memory_limit`; further allocation returns out-of-memory inside the sandbox. |
| `max_output_bytes` | `1048576` (1 MB) | Engine truncates serialized output past the cap; reports `cap-exceeded`. |

A violation of any cap:

1. Terminates the script.
2. Returns `ScriptOutcome::CapExceeded { which, budget_used }` to the calling skill.
3. Emits an `AfterTool` event with `outcome: cap-exceeded` and the exhausted cap.
4. Does **not** panic the host. The daemon continues.

The kernel imposes a hard ceiling on per-invocation budgets so an operator config cannot grant a single script the entire host:

- `max_execution_ms` ceiling: `30000` (30 s).
- `max_memory_kb` ceiling: `262144` (256 MB).
- `max_output_bytes` ceiling: `16777216` (16 MB).

Operator configs that exceed the ceiling are clamped at load time and a warning is logged; scripts requesting larger per-invocation budgets are denied at invocation time.

### Config schema

Under `[scripting]` in TOML:

```toml
engine            = "disabled"                                 # or "lua"
max_execution_ms  = 1000
max_memory_kb     = 65536
max_output_bytes  = 1048576
allow_stdlib      = ["string", "math", "table"]
deny_stdlib       = ["io", "os", "package", "require", "debug", "coroutine"]
```

Strict is the only supported posture in v0.12; there is no config key that turns off the sandbox. This keeps the policy surface small and forecloses a "we'll just turn off the sandbox for this one skill" failure mode.

The `allow_stdlib` list MAY be widened by the operator (e.g. to add `bit32`); `deny_stdlib` is treated as the hard floor — anything in `deny_stdlib` cannot be re-allowed by adding it to `allow_stdlib`. If a library appears in both lists, the effective allowlist drops it and logs a warning. This mirrors ADR 0034's `security.exec_deny` precedence over `security.exec_allow`.

### Two-step opt-in

Enabling Lua end-to-end requires both:

1. `security.exec_allow` includes `"lua"` (per ADR 0034's interpreter opt-in pattern). This is the "skill scripts can declare lua as their interpreter" gate.
2. `scripting.engine = "lua"` at the top level of config. This is the "kernel actually instantiates the engine" gate.

Neither is defaulted on. Fresh profiles ship with Lua disabled. The install preview (ADR 0033) surfaces required interpreters so a skill that declares Lua scripts tells the operator up front.

### Hooks observability

Every embedded-script invocation records `budget_used` (instructions executed, peak memory bytes, wall ms, output bytes) in the `AfterTool` metadata. The synthetic tool name follows ADR 0069's convention (`exec.lua:<skill>/<script>`). Operators can audit Lua usage per session from the existing hook log surface — no new audit pipeline.

### Sandbox-escape policy

If any future audit reveals that a script can escape the sandbox (read files, make network calls, mutate host memory) under the documented `strict` policy, that is a security defect handled like any other: a fix lands in the engine; if a fix is not feasible, the engine is disabled in fresh profiles via a release note pending mitigation. The sandbox policy in this ADR is a **contract**, not a hope: an implementation that cannot satisfy it does not satisfy ADR 0069 either.

## Consequences

**Positive**

- One sandbox policy contract that ADR 0069's trait makes uniform across engines.
- Three independent caps mean a misbehaving script cannot tie up the host on any single axis.
- `deny_stdlib` as a hard floor prevents the gradual "just allow `os.getenv`, what could go wrong?" drift.
- Two-step opt-in (engine + interpreter allowlist) means Lua is genuinely off by default.

**Negative**

- Operators authoring Lua skills must understand the cap shape; a default-`max_execution_ms` of 1 second will surprise authors who expect "scripting" to mean unbounded.
- The hard ceilings on per-invocation budgets cap legitimate use cases (e.g. a 1-minute computation). Acceptable: those cases should run as a subprocess via ADR 0034, not as an embedded script.

**Neutral**

- The default allowlist (`string`, `math`, `table`) is intentionally minimal. Skill authors who need `bit32`, `utf8`, or other libraries opt in explicitly per profile.
- `coroutine` is denied by default; can be revisited in a later release if a real use case arrives.

## References

- [docs/plans/v0.12-self-improvement.md](../plans/v0.12-self-improvement.md)
- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0006](0006-hook-api-is-public-from-day-one.md)
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0069](0069-scripting-engine-trait-with-lua-as-the-v0-12-default-embedded-runtime.md)
- [mlua memory limits](https://docs.rs/mlua/latest/mlua/struct.Lua.html#method.set_memory_limit)
- [Lua 5.4 standard library](https://www.lua.org/manual/5.4/manual.html#6)
