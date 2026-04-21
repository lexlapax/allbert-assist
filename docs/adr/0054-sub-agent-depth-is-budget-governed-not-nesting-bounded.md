# ADR 0054: Sub-agent depth is governed by cost/time budget, not nesting count

Date: 2026-04-20
Status: Proposed

## Context

v0.5 caps sub-agent spawning at one nested level per [v0.3](../plans/v0.3-agent-harness.md) and the [v0.5 plan](../plans/v0.5-curated-memory.md). The cap protects against runaway loops and unbounded cost.

Real multi-step workflows routinely need more depth. A research task might spawn a reader sub-agent per source; each reader might spawn a targeted follow-up for a specific claim. Channel-driven workflows in v0.7 (especially Telegram queries that expand into multi-step investigations) will hit the one-level cap immediately.

Nesting count is a crude proxy for the real concern: runaway cost and latency. A one-level cap blocks legitimate three-level work while permitting a single-level spawn that itself consumes an entire budget. The v0.6 hard cost cap (ADR 0051) and the v0.2 job-manager time budgets already exist as the right currencies for the concern. The cap should be expressed in them.

## Decision

Effective v0.7, sub-agent spawning is no longer bounded by nesting count. Each sub-agent inherits from its parent at spawn time:

- `remaining_budget_usd` = parent's remaining budget − parent's turn cost so far
- `remaining_budget_s` = parent's remaining deadline − elapsed time

A sub-agent spawning its own sub-agent further subdivides the same budgets. When either budget reaches zero, the spawn refuses with `budget-exhausted` (the spawning agent receives a tool error; the user receives a clear message).

### Root-turn budget sources

- `limits.max_turn_usd` (default: $0.50)
- `limits.max_turn_s` (default: 120 seconds)

Raised per-turn from REPL via:

- `/cost --turn-budget <usd>`
- `/cost --turn-time <s>`

Channel-originated turns inherit channel defaults (v0.7 Channel trait extension). Job-originated turns inherit the job's declared budget (ADR 0022 frontmatter + defaults).

### Daily cap interaction

ADR 0051's daily cap overrides per-turn budget. A per-turn budget of $2.00 when the daily cap has $0.10 remaining gives the agent $0.10 to spend, not $2.00. Sub-agent spawns respect the lower of the two bounds.

### Spawn-refusal handling

`spawn_subagent` with exhausted budget returns a structured error the parent agent can read. The parent may:

- return what it has so far to the user
- ask the user to raise the turn budget
- narrow the scope of the remaining work

This is a prompt-level policy; bootstrap prompts (`AGENTS.md`, `TOOLS.md`) document the expected behaviour.

## Consequences

**Positive**

- Real multi-step workflows (research, multi-source synthesis, iterated code review) become feasible.
- The failure mode is expressed in the currency of the real concern (cost, time) rather than a proxy (nesting).
- Budget accounting plugs into existing CostHook and job-manager infrastructure; no new currency.

**Negative**

- Budget arithmetic must be correct at every spawn boundary. Bugs can leak budget, either refusing too early or allowing overspend. The kernel's test suite gains budget-tracking cases.
- Aggressive budget requests can concentrate spend in one deep branch at the expense of later turns in the same session. Session-level budgets are not part of this ADR; they are a future concern if users report the pattern as painful.
- A deeply nested spawn tree generates more tokens in aggregate, increasing the odds of hitting provider rate limits unrelated to cost.

**Neutral**

- Supersedes the one-level cap from v0.5. Existing sub-agent semantic contracts (filtered memory context, agent definition hand-off) are unchanged; only the spawn gate moves.
- The turn-budget settings introduced here are new config/runtime surface; v0.7 does not assume any previously shipped `max_sub_agent_depth` config key.
- Hooks observing `spawn_subagent` see budget state in `HookCtx` for custom policy.

## References

- [docs/plans/v0.3-agent-harness.md](../plans/v0.3-agent-harness.md)
- [docs/plans/v0.5-curated-memory.md](../plans/v0.5-curated-memory.md) — one-level cap this ADR lifts.
- [docs/plans/v0.7-channel-expansion.md](../plans/v0.7-channel-expansion.md)
- [ADR 0022](0022-job-definitions-are-markdown-with-frontmatter-and-a-bounded-schedule-dsl.md)
- [ADR 0029](0029-agents-are-first-class-runtime-participants.md)
- [ADR 0044](0044-subagents-receive-filtered-memory-context-not-full-parent-recall.md)
- [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)
