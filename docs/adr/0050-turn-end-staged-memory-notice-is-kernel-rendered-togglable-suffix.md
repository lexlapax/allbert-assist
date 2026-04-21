# ADR 0050: Turn-end staged-memory notice is a kernel-rendered togglable suffix

Date: 2026-04-20
Status: Accepted

## Context

v0.5 did not leave staging silent after all: the shipped runtime already appends a short turn-end hint when a turn creates staged entries, guarded by `memory.surface_staged_on_turn_end`. What remains missing is not the existence of the notice, but the decision that this shipped suffix is the canonical surface and that any v0.6 refinement must evolve that surface rather than rename it.

The retrospective on 2026-04-20 accepted "keep the short turn-end hint, optionally make it more review-friendly" as the right hardening path. v0.6 commits that decision.

## Decision

After every turn that stages at least one memory entry, the kernel renders a short suffix on the assistant's final message summarising what was staged and how to inspect it. This is the same feature v0.5 already shipped; v0.6 may refine the rendering, but it does not introduce a second config key or a separate notice mechanism.

Example rendering:

```
(staged 2 — 01HX… "we use postgres for primary storage" · 01HX… "gmail is lexlapax@gmail.com" — run `memory staged show <id>` to inspect)
```

### Rules

- Emitted only when at least one entry was staged in the completed turn.
- Togglable via the existing `memory.surface_staged_on_turn_end = true|false`. Default remains `true` on fresh profiles; upgrades preserve existing behaviour.
- The baseline rendering may remain the shipped one-line count-and-pointer form. If v0.6 enriches it with per-entry summaries, those summaries stay tightly bounded and do not change the feature's kernel-owned nature.
- **Kernel-rendered, not skill-rendered.** Staging is a kernel-native operation; the notice belongs with the writer, not with any one curator.
- Channel-adaptive (in anticipation of v0.7):
  - Synchronous channels (REPL, Telegram once it ships) render inline as a suffix.
  - Asynchronous channels append the notice to the next outbound message.
  - Batch-only channels (future SMS etc.) may omit the suffix; operators rely on `memory staged list` instead.
- The notice itself is not recorded to memory. It is a surface rendering, not a persisted artifact.

## Consequences

**Positive**

- Closes the silent-staging UX gap without adding a new CLI command or requiring the user to run `memory staged list`.
- Every staging path (explicit `stage_memory` tool call, curator agent, future auto-learning from `web_search` with `record_as`) gets the same surface for free.
- Kernel ownership means the behaviour is consistent across channels and cannot be subtly re-implemented by every skill.

**Negative**

- Cross-cutting rendering that must respect channel capability flags (v0.7 work). Until v0.7 lands, only REPL is exercised.
- Users who find the notice noisy must know about the toggle; onboarding wizard should surface it.

**Neutral**

- Does not change the caps, TTL, or dedup behaviour from ADR 0047.
- The `memory-curator` skill (ADR 0048) still owns the review workflow; the turn-end notice is a *pointer* to that workflow, not a replacement.

## References

- [ADR 0042](0042-autonomous-learned-memory-writes-go-to-staging-before-promotion.md)
- [ADR 0047](0047-staged-memory-entries-have-a-fixed-schema-and-limits.md)
- [ADR 0048](0048-v0-5-ships-a-first-party-memory-curator-skill.md)
- [docs/plans/v0.6-foundation-hardening.md](../plans/v0.6-foundation-hardening.md)
