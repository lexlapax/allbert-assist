# Scripting operator guide

v0.12 adds an embedded scripting seam with one implementation: Lua 5.4 through `mlua`. Lua is JSON-in/JSON-out, sandboxed by default, and disabled unless the operator enables both required gates.

## When To Use Lua

Use embedded Lua for small in-process transforms:

- scoring or filtering JSON records
- deterministic string/math/table manipulation
- many tiny calls where subprocess startup would dominate

Use subprocess scripts such as Python or Bash when you need filesystem access, network access, long-running computation, external tools, or broad standard libraries. Those continue to run through the existing exec policy.

## Two-Gate Opt-In

Fresh profiles keep Lua off:

```toml
[scripting]
engine = "disabled"
max_execution_ms = 1000
max_memory_kb = 65536
max_output_bytes = 1048576
allow_stdlib = ["string", "math", "table"]
deny_stdlib = ["io", "os", "package", "require", "debug", "coroutine"]

[security]
exec_allow = ["bash", "python"]
```

Enable Lua only when you want embedded Lua skill scripts to run:

```toml
[scripting]
engine = "lua"

[security]
exec_allow = ["bash", "python", "lua"]
```

Both gates are required. If either is missing, `run_skill_script` refuses Lua with an operator-readable error.

## Skill Frontmatter

Lua scripts use the existing AgentSkills `scripts:` shape:

```yaml
scripts:
  - name: score
    interpreter: lua
    path: scripts/score.lua
```

There is no separate `lua_scripts:` section.

## Runtime Contract

Lua receives JSON input and returns JSON output. It cannot hold Rust references, access session state, read memory services directly, or call host tools from inside the VM. Any follow-up action after a Lua result must go through the normal tool surface outside the Lua VM.

The tool input may include `input` JSON and an optional per-call budget:

```json
{
  "skill": "summarizer",
  "script": "score",
  "input": { "title": "Release notes" },
  "budget": {
    "max_execution_ms": 1000,
    "max_memory_kb": 65536,
    "max_output_bytes": 1048576
  }
}
```

## Sandbox Policy

The v0.12 implementation uses Lua 5.4 with an explicit standard-library allowlist. The default allowlist is:

- `string`
- `math`
- `table`

The default deny floor is:

- `io`
- `os`
- `package`
- `require`
- `debug`
- `coroutine`

Anything in `deny_stdlib` wins over `allow_stdlib`; denied entries are removed from the effective allowlist at config load with a warning. Under the default strict posture, Lua cannot read files, spawn processes, load modules, make network calls, or introspect host state.

## Caps And Ceilings

Three caps are enforced by the engine and reported in hook metadata:

| Cap | Default | Hard ceiling |
| --- | --- | --- |
| `max_execution_ms` | `1000` | `30000` |
| `max_memory_kb` | `65536` | `262144` |
| `max_output_bytes` | `1048576` | `16777216` |

Operator config above the hard ceiling is clamped at load time with a warning. Per-invocation budgets above the hard ceiling are denied.

Cap exhaustion returns `cap-exceeded` instead of panicking the daemon.

## Hook Observability

Embedded scripts emit synthetic tool names:

```text
exec.lua:<skill-name>/<script-path>
```

`AfterTool` metadata includes `budget_used` with instruction count, peak memory bytes, wall-clock milliseconds, and output bytes.

## Related Docs

- [Skill authoring guide](skill-authoring.md)
- [Self-improvement guide](self-improvement.md)
- [v0.12 upgrade notes](../notes/v0.12-upgrade-2026-04-25.md)
