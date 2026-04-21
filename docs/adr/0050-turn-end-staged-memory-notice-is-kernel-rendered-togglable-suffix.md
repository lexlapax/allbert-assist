# ADR 0050: Turn-end staged-memory notice is a kernel-rendered togglable suffix

Date: 2026-04-20
Status: Proposed

## Context

v0.5 staging (ADR 0042, 0047, 0048) is silent by design: the `memory-curator` skill or an agent call to `stage_memory` writes a candidate entry without interrupting the conversational flow. The 5-per-turn cap and 90-day TTL bound accumulation, but users rarely run `memory staged list` on their own cadence. Entries that are not surfaced at the moment of creation are unlikely to ever be promoted — which breaks the promotion loop the feature exists to serve.

The retrospective on 2026-04-20 explicitly accepted "short turn-end hint, togglable" as the recommended UX. v0.6 commits that decision.

## Decision

After every turn that stages at least one memory entry, the kernel renders a short suffix on the assistant's final message summarising what was staged and how to inspect it.

Example rendering:

```
(staged 2 — 01HX… "we use postgres for primary storage" · 01HX… "gmail is lexlapax@gmail.com" — run `memory staged show <id>` to inspect)
```

### Rules

- Emitted only when at least one entry was staged in the completed turn.
- Togglable via `memory.turn_end_notice = true|false`. Default `true` on fresh v0.6 profiles; unchanged on upgrade (existing profiles default to whatever is explicitly set, or `true` if the key is absent).
- Combined id + summary truncated to 120 chars per entry. More than three entries collapses to "staged N — run `memory staged list --since-session` to inspect."
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
