# ADR 0029: Agents are first-class runtime participants

Date: 2026-04-18
Status: Accepted

## Context

v0.2 delivered a multi-session kernel (ADR 0021) but each session still runs a single monolithic agent loop. v0.3 introduces orchestrator / sub-agent patterns — for example, a research-oriented root agent delegating a focused lookup to a reader sub-agent. Two shapes were considered:

1. Skill-level orchestration: skills activate other skills and stitch their outputs inline. Runtime topology stays implicit in prompt templates.
2. First-class `Agent` abstraction: the kernel knows about agents. Orchestrator agents may spawn sub-agents via an explicit built-in tool. Each sub-agent runs with its own message history, its own `allowed-tools` fence (ADR 0008), and its own skill activations, sharing only session-scoped singletons.

Option 1 keeps today's shape but conflates prompt composition with runtime topology, hides delegation from hooks and cost tracking, and makes the security fence ambiguous for sub-work.

Option 2 adds a small trait and a single built-in tool while preserving the kernel-is-runtime-core principle (ADR 0001). Every sub-agent turn runs through the same hook, cost, and policy surface as any other turn.

## Decision

Agents are first-class runtime participants.

- `Agent` is a trait owned by the kernel. Every session has a root agent that the kernel spawns on `create_session` (ADR 0021).
- Orchestrator agents may call a new built-in tool `spawn_subagent(name, prompt, context)`. The sub-agent runs inline in the same session, returns a structured result, and is torn down.
- A sub-agent inherits session-scoped singletons (hook registry, tool registry, provider client pool) but gets its own message history, its own turn counter, and its own cost accumulator. Confirm-trust approvals (ADR 0007) remain session-scoped and are shared across agents within a session.
- v0.3 forbids recursive sub-agent spawning: sub-agents may not spawn their own sub-agents. A single level of delegation is enough to validate the shape without opening an unbounded topology.
- `HookCtx` (ADR 0006) gains `agent_name` and `parent_agent_name` fields. Every hook point fires for sub-agent turns just as for root turns.
- Sub-agent transcripts surface to the caller as tool output. They are not merged into the parent's message list; the orchestrator decides what to quote or summarise.
- Cost, trace, and run metadata attribute each turn to its agent so failures are diagnosable.

## Consequences

**Positive**
- Makes orchestration behaviour auditable via hooks, cost logs, and traces rather than buried in prompt templates.
- Keeps the delegation surface uniform whether the orchestrator was authored by a user or shipped as a bundled template.
- Preserves the kernel-is-runtime-core framing (ADR 0001) — agents are a new kind of participant, not a parallel runtime.

**Negative**
- Adds a small trait plus one built-in tool to the kernel.
- Requires a kernel-level recursion guard in v0.3.

**Neutral**
- Future releases can relax the single-level recursion bound once observable behaviour is well understood.
- A future "agent registry" or "agent catalog" is a natural follow-on but not a v0.3 requirement.

## References

- [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md)
- [ADR 0006](0006-hook-api-is-public-from-day-one.md)
- [ADR 0007](0007-session-scoped-exact-match-confirm-trust.md)
- [ADR 0008](0008-skill-allowed-tools-is-a-fence-not-a-sandbox.md)
- [ADR 0016](0016-scheduled-runs-use-fresh-sessions-and-may-attach-ordered-skills.md)
- [ADR 0021](0021-kernel-multiplexes-sessions-shared-runtime-per-session-state.md)
- [docs/plans/v0.03-agent-harness.md](../plans/v0.03-agent-harness.md)
