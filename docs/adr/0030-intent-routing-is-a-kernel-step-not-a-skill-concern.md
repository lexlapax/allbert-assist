# ADR 0030: Intent routing is a kernel step, not a skill concern

Date: 2026-04-18
Status: Accepted

## Context

v0.3 introduces intent classification: understanding what a user turn wants so the root agent can pick appropriate skills, spawn the right sub-agent, or route to the scheduler. Two shapes were considered:

1. A "router" skill at the top of every session prompt decides what to do.
2. Intent classification is a kernel step that runs before agent turn construction, with a bounded taxonomy, rule-based fast paths, and an LLM sub-call fallback.

Option 1 makes routing invisible to hooks, cost logs, and policy — every change to routing behaviour means rewriting prompt templates. Option 2 gives routing a proper seam: hooks can observe it, cost is tracked, and the classifier is swappable without rewriting skills.

## Decision

Intent routing is a kernel step.

- v0.3 ships a bounded taxonomy: `{task, chat, schedule, memory_query, meta}`. Any expansion is a minor-version change, not an ad hoc skill concern.
- Classification runs in two stages: rule-based fast paths (keyword / shape heuristics) first, LLM sub-call fallback when rules are ambiguous or return low confidence.
- New hook points `BeforeIntent` and `AfterIntent` allow external code to observe, override, or short-circuit classification.
- The resolved `Intent` lands on `HookCtx` and is available to skills and agents as declarative context. It is a hint that guides skill selection and sub-agent choice — it is not a hard gate.
- The classifier sub-call runs through the same provider client pool, cost log, and trace surface as any other LLM call. It is attributed as `intent-classifier` in cost logs.
- The classifier output is cacheable per turn; the kernel does not re-run it for the same input within a session.

## Consequences

**Positive**
- Gives routing behaviour one canonical location owned by the kernel.
- Cost, trace, and hook surfaces see the classifier sub-call; there are no invisible prompt tricks.
- Skills stop carrying routing logic that rightfully belongs in the runtime.

**Negative**
- Adds a potentially small LLM sub-call to some turns. Must be cheap; rules must carry the common cases.
- Taxonomy expansion means a kernel change rather than a prompt change.

**Neutral**
- A future pluggable classifier (e.g. user-owned classification skill that wraps the built-in one) fits cleanly into this seam without a redesign.
- Intent state is session-scoped (ADR 0021); classifiers do not share state across sessions.

## References

- [ADR 0006](0006-hook-api-is-public-from-day-one.md)
- [ADR 0021](0021-kernel-multiplexes-sessions-shared-runtime-per-session-state.md)
- [ADR 0029](0029-agents-are-first-class-runtime-participants.md)
- [docs/plans/v0.3-agent-harness.md](../plans/v0.3-agent-harness.md)
