# ADR 0052: Kernel-native operations promote to Tool implementations

Date: 2026-04-20
Status: Accepted

## Context

A retrospective on 2026-04-20 identified that Allbert has a two-tier tool surface:

- `ToolRegistry` holds six tools: `process_exec`, `read_file`, `write_file`, `request_input`, `web_search`, `fetch_url`. These go through `Tool::call` and are observed by `BeforeTool`/`AfterTool` hooks.
- Everything else — memory ops (`read_memory`, `write_memory`, `search_memory`, `stage_memory`, `list_staged_memory`, `promote_staged_memory`, `reject_staged_memory`, `forget_memory`), skill ops (`list_skills`, `invoke_skill`, `create_skill`, `read_reference`, `run_skill_script`), and `spawn_subagent` — is dispatched directly in the kernel agent loop. Hooks do not see them.

The two-tier world has three costs:

1. **Hook gaps.** `BeforeTool`/`AfterTool` observe only the six registry tools. `SecurityHook`, `CostHook`, and future operator-authored hooks cannot uniformly gate or audit memory/skill operations.
2. **No community tool seam.** Skill-authored custom tools cannot exist unless they go through one of the six bypasses or fork the kernel.
3. **Documentation drift.** README.md reads as if memory and skill ops are tools. Code disagrees. Operators reading the codebase find a confusing split.

The reason the split exists: memory and skill operations need direct access to kernel state (memory indices, skill store, session ephemeral tier). The v0.1 shape captured that state in closure-free handlers rather than pushing it through `ToolCtx`.

## Decision

In v0.7, memory, skill, and sub-agent kernel-native handlers are reimplemented as `Tool` trait implementations and registered in `ToolRegistry::builtins()`:

- Memory tools: `read_memory`, `write_memory`, `search_memory`, `stage_memory`, `list_staged_memory`, `promote_staged_memory`, `reject_staged_memory`, `forget_memory`.
- Skill tools: `list_skills`, `invoke_skill`, `create_skill`, `read_reference`, `run_skill_script`.
- Agent tools: `spawn_subagent`.

Kernel state is injected via a `ToolCtx` extension mechanism:

```rust
pub struct ToolCtx {
    pub input: Arc<dyn InputPrompter>,
    pub security: SecurityConfig,
    pub web_client: reqwest::Client,
    pub memory: Arc<MemoryService>,   // new
    pub skills: Arc<SkillStore>,      // new
    pub session: Arc<SessionHandle>,  // new
}
```

The agent loop calls `ToolRegistry::dispatch` uniformly for every tool. `BeforeTool` / `AfterTool` hooks observe every tool call without exception. `SecurityHook` can gate memory writes with the same policy it applies to `process_exec`.

### Capability fence compatibility

Skill `allowed-tools` (ADR 0008) continues to work. A skill that lists `allowed-tools: [search_memory, read_memory]` can invoke those tools but not `write_memory`, just as today a skill fences `process_exec`.

### Backward compatibility

The v0.5 tool-call protocol does not change from the model's perspective — the same tool names with the same input schemas. Only the internal dispatch path changes.

## Consequences

**Positive**

- Hooks see every tool call. Uniform policy observability across the full surface.
- Skill-authored custom tools become feasible in a future release because `ToolRegistry` is the single extension seam.
- Prompt-catalog rendering is unified; README no longer diverges from code.
- `SecurityHook` gains the ability to apply the same confirm-trust model to memory writes that it currently applies to destructive filesystem operations.

**Negative**

- Refactor touches most of `crates/allbert-kernel/src/lib.rs`. Non-trivial, though the kernel's 61 tests provide a safety net.
- `ToolCtx` extensions must be thread-safe (already `Arc`-wrapped) and cheap to clone per invocation.
- Dispatch overhead increases slightly (one more layer), but is lost in the cost of an LLM turn.

**Neutral**

- The `Tool` trait itself is unchanged; only the membership of the registry grows.
- External plugin-system work is still deferred. This ADR only normalises internal shape.
- `ChannelKind::{Cli, Repl, Jobs}` and the v0.7 channel expansion are unaffected; they consume dispatched tool outcomes the same way.

## References

- v0.1 plan — initial `ToolRegistry::builtins()`.
- [ADR 0006](0006-hook-api-is-public-from-day-one.md) — hook API.
- [ADR 0008](0008-skill-allowed-tools-is-a-fence-not-a-sandbox.md) — capability fence survives the refactor.
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md) — end-user-facing contract unchanged; tools are model-facing.
- [docs/plans/v0.7-channel-expansion.md](../plans/v0.7-channel-expansion.md)
