# ADR 0030: Intent routing is a kernel step, not a skill concern

Date: 2026-04-18
Status: Accepted

> **v0.14.3 amendment**: default intent routing moves from semantic keyword
> fast paths to a schema-bound LLM router that runs before full prompt assembly.
> The router remains kernel-owned, internal, and trace/cost-attributed. It may
> emit guarded schedule and explicit-memory action drafts, but those drafts are
> executed only through existing Allbert tool, preview, and staging surfaces.
> This supersedes semantic keyword fast paths as the default routing authority;
> legacy rule classification remains only behind `intent_classifier.rule_only =
> true`. When `intent_classifier.enabled = false`, routing stays disabled and no
> router action draft is produced.
>
> **v0.15.1 amendment**: the router may grow from broad intent classification
> into a bounded structured turn plan. The plan is non-mutating runtime guidance
> distinct from terminal action drafts: it can say the turn should answer
> directly, clarify, retrieve evidence, or call an available tool first. A web
> search request is the motivating acceptance case, but the design is capability
> routing rather than a one-off current-info flag. This remains kernel-owned,
> trace/cost-attributed, schema-bound, and policy-aware. It does not expand
> terminal router mutations beyond the existing schedule and explicit-memory
> action drafts, and it does not permit tools to bypass active-skill or security
> policy.

## Context

v0.3 introduces intent classification: understanding what a user turn wants so the root agent can pick appropriate skills, spawn the right sub-agent, or route to the scheduler. Two shapes were considered:

1. A "router" skill at the top of every session prompt decides what to do.
2. Intent classification is a kernel step that runs before agent turn construction, with a bounded taxonomy, rule-based fast paths, and an LLM sub-call fallback.

Option 1 makes routing invisible to hooks, cost logs, and policy — every change to routing behaviour means rewriting prompt templates. Option 2 gives routing a proper seam: hooks can observe it, cost is tracked, and the classifier is swappable without rewriting skills.

## Decision

Intent routing is a kernel step.

- v0.3 ships a bounded taxonomy: `{task, chat, schedule, memory_query, meta}`. Any expansion is a minor-version change, not an ad hoc skill concern.
- Classification originally ran in two stages: rule-based fast paths (keyword / shape heuristics) first, LLM sub-call fallback when rules are ambiguous or return low confidence. This remains the v0.3-v0.14.2 history and the v0.14.3 `intent_classifier.rule_only = true` compatibility path, but is no longer the v0.14.3 default.
- New hook points `BeforeIntent` and `AfterIntent` allow external code to observe, override, or short-circuit classification.
- The resolved `Intent` lands on `HookCtx` and is available to skills and agents as declarative context. It is a hint that guides skill selection, preferred agents, prompt shaping, confirmation style, and other routing defaults — it is not a hard gate.
- Later releases may let intent bias tool ordering or default behaviour, but they do not remove tools from the runtime or create intent-exclusive tool surfaces without a separate ADR that explicitly revisits this decision.
- The classifier/router sub-call runs through the same provider client pool, cost log, and trace surface as any other LLM call. v0.3-v0.14.2 attributed it as `intent-classifier`; v0.14.3 default router calls are attributed as `intent-router`.
- The classifier output is cacheable per turn; the kernel does not re-run it for the same input within a session.

### v0.14.3 router-first amendment

v0.14.3 changes the default implementation shape without changing the
kernel-owned-routing decision:

- Default routing uses a structured `RouteDecision` JSON object from the LLM
  router. Legacy rule classification remains available only when
  `intent_classifier.rule_only = true`; disabled routing remains disabled.
- The router receives bounded routing context only: user message, source/channel,
  current time/timezone, last resolved intent, pending confirmation state, and a
  bounded job-name index. It does not receive bootstrap files, full memory,
  skill bodies, or tool results.
- The router may emit action drafts only for
  `schedule_upsert`, `schedule_pause`, `schedule_resume`, `schedule_remove`, and
  `memory_stage_explicit`.
- All action drafts require high confidence, no clarification request, schema
  validation, and complete action fields before the kernel converts them into a
  synthetic runtime action.
- Router action conversion is terminal for the turn when it succeeds. Allbert
  records a deterministic operator-facing notice and does not persist a fake
  assistant-authored message for the router decision.
- Router failure, low confidence, malformed JSON, or missing fields fails
  closed: no mutation occurs.

### v0.15.1 structured turn-plan amendment

v0.15.1 recognizes that broad intent alone is not enough for local-model tool
reliability. A prompt can be ordinary `task` or `chat` while still requiring a
specific capability before a truthful answer: fresh web evidence, local memory,
RAG context, a file read, a clarification, or a job/status surface. That is not
a terminal router action and should not be encoded as one.

- The router may add a bounded structured turn plan to `RouteDecision` for
  non-mutating runtime guidance. Useful fields include an execution path,
  required capabilities, preferred or required tools, an evidence policy, and a
  mutation-risk classification.
- The plan may bias prompt assembly, preferred tool ordering, deterministic
  policy messaging, and missing-tool-call retry eligibility. It must not execute
  a tool by itself. After the bounded retry fails, the kernel may synthesize a
  first tool call only for the narrow v0.15.1 read-only `web_search` bridge
  documented in ADR 0096; the router still does not execute tools directly.
- The plan remains observable through existing intent, trace, and cost surfaces.
  It is not hidden inside a skill prompt.
- Active-skill allowlists and security policy still decide whether a tool is
  actually available. If the plan requires `web_search` but policy hides it, the
  runtime reports policy reality instead of encouraging a bypass.
- Explicit operator tool requests and implicit evidence needs both fit this
  structure. `web search for rust shell library` should become a read-only
  `tool_first` plan requiring the `clear_web` capability and `web_search` tool.
  `what's today's top news?` should reach the same plan through freshness and
  public-world cues.
- Router-provided tool names and capabilities are validated against the kernel's
  bounded registry. Unknown capabilities, unknown tools, and tools not visible
  under active policy fail closed to ordinary answer/clarification behavior or a
  deterministic policy message, depending on the user request.
- Fresh/current-info routing is separate from ADR 0053 web learning. Searching
  to answer a fresh question does not stage or remember results unless the user
  explicitly asks to remember them.

## Consequences

**Positive**
- Gives routing behaviour one canonical location owned by the kernel.
- Cost, trace, and hook surfaces see the classifier sub-call; there are no invisible prompt tricks.
- Skills stop carrying routing logic that rightfully belongs in the runtime.

**Negative**
- Adds a potentially small LLM sub-call to some turns. From v0.14.3 onward the router call must be cheap and bounded; semantic keyword rules no longer carry common cases by default.
- Taxonomy expansion means a kernel change rather than a prompt change.

**Neutral**
- A future pluggable classifier (e.g. user-owned classification skill that wraps the built-in one) fits cleanly into this seam without a redesign.
- Intent state is session-scoped (ADR 0021); classifiers do not share state across sessions.

## References

- [ADR 0006](0006-hook-api-is-public-from-day-one.md)
- [ADR 0021](0021-kernel-multiplexes-sessions-shared-runtime-per-session-state.md)
- [ADR 0029](0029-agents-are-first-class-runtime-participants.md)
- [docs/plans/v0.03-agent-harness.md](../plans/v0.03-agent-harness.md)
- [docs/plans/v0.14.3-operator-reliability.md](../plans/v0.14.3-operator-reliability.md)
- [docs/plans/v0.15.1-feature-test-followups.md](../plans/v0.15.1-feature-test-followups.md)
