# ADR 0021: Kernel multiplexes sessions with shared runtime and per-session state

Date: 2026-04-18
Status: Proposed

## Context

v0.1 built the kernel as a single-session runtime. One `Kernel` owns one `AgentState { session_id, messages, active_skills, turn_count, cost_total_usd }` inline, alongside configuration, hooks, tools, provider factory, LLM client, security state, and the frontend adapter. That shape fit v0.1 because only the REPL ever ran, and only ever one session at a time.

v0.2 changes that. The daemon must host at least three kinds of concurrent sessions:

- one persistent interactive REPL session that clients can attach to and detach from
- zero or more scheduled job sessions launched as fresh, non-interactive runs
- future one-shot CLI command sessions that may be short-lived

There are two obvious ways to structure this:

1. **Kernel-per-session.** The daemon holds `HashMap<SessionId, Kernel>`. Each session gets its own Kernel instance, independently initialized.
2. **Session-multiplexing kernel.** A single `Kernel` owns many sessions internally, sharing runtime singletons (config defaults, hooks, tools, provider factory, provider client pool) and scoping conversation state, skill activations, confirm-trust, and effective model selection per session.

Option 1 looks simpler but is wrong for Allbert. Hooks, tool registry, provider clients, cost log writers, and tracing guards are meant to be process-wide singletons. Duplicating them per session wastes resources, fragments trace/cost output, and scatters configuration across parallel Kernel instances. It also breaks the "one kernel = the runtime core" framing: there would effectively be N runtime cores.

Option 2 preserves the kernel-first principle: the Kernel is still the runtime core, it just now manages session lifecycle alongside its existing responsibilities.

## Decision

The kernel multiplexes sessions. One `Kernel` instance owns many sessions concurrently; runtime singletons are shared and session-scoped state lives per session.

- **Shared across all sessions (owned by `Kernel`):** configuration defaults, paths, tool registry, hook registry, provider factory, provider client pool, tracing handles, cost log writer, skill store.
- **Per session (owned by a `Session` record, keyed by `SessionId`):** conversation messages, turn counter, active skills, session cost total, confirm-trust approvals (per ADR 0007), frontend adapter handle, input/confirm prompter handles, effective model config.
- The kernel exposes explicit session lifecycle methods: `create_session`, `run_turn(session_id, …)`, `end_session`, `snapshot_session`.
- Hooks must receive the `SessionId` in `HookCtx` and treat session-scoped state as keyed data rather than ambient state.
- Confirm-trust approvals (ADR 0007) remain strictly session-scoped and never leak across sessions.
- Scheduled job sessions are created fresh and ended when the run finishes; they never inherit state from other sessions (consistent with ADR 0016).
- The REPL session is long-lived: disconnecting and reattaching a channel client does not end the session.
- The daemon-wide `[model]` config is only the default for new sessions. Interactive `/model` changes affect the attached session only, and jobs may carry their own explicit model override.

## Consequences

**Positive**
- Preserves "Kernel is the runtime core" while enabling the daemon host described in ADR 0018.
- Shares expensive singletons (hook registry, provider clients, tool registry) across sessions.
- Gives session-scoped security state (ADR 0007) a clean home without global mutation.
- Keeps cost, trace, and memory streams unified at the daemon level.
- Prevents one user's `/model` change from unexpectedly mutating every other live session on the daemon.

**Negative**
- Kernel state becomes concurrent; session operations must be safe under concurrent access. A `RwLock`-keyed session map plus `Arc`-shared singletons is likely the right shape.
- `HookCtx` grows a required `session_id` field; all existing hooks must be updated.
- Per-session cost totals and ambient state need reset semantics that `reset()` in v0.1 took for granted.
- The old single active `LLM client` shape becomes a provider-client pool plus per-session effective model resolution.

**Neutral**
- Future work can still introduce richer session persistence (durable resumption) without changing this model.
- Frontends remain adapters; they just now carry a `SessionId` when talking to the kernel.
- This decision does not dictate whether sessions run turns serially or concurrently within a session — only across sessions.

## References

- [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md)
- [ADR 0007](0007-session-scoped-exact-match-confirm-trust.md)
- [ADR 0016](0016-scheduled-runs-use-fresh-sessions-and-may-attach-ordered-skills.md)
- [ADR 0018](0018-kernel-must-be-capable-of-running-as-a-long-lived-daemon-host.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
