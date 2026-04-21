# ADR 0053: Background web-learning stages results only under explicit user intent

Date: 2026-04-20
Status: Proposed

## Context

The origin note (2026-04-17) envisions Allbert learning silently from web searches — "Google search records things and maintains a record of what I searched for." Through v0.5, `web_search` (DuckDuckGo HTML scrape) and `fetch_url` (HTTP page fetch + HTML strip) are on-demand only; there is no path from search result to durable memory.

The 2026-04-20 retrospective flagged two candidate designs:

1. **Auto-stage every search.** Every `web_search` call auto-stages a candidate memory with source URL and snippet. High recall, high false-positive rate, privacy concerns.
2. **Explicit user-intent trigger.** The agent stages only when the user says so — e.g. "look that up and remember it." Low auto-recall but high precision and privacy-by-default.

Option 1 would silently build a record of every search — including searches the user regrets, explores, or performs in a professional context the assistant should not conflate with the personal profile. That is at odds with the staging/promotion trust model: staged entries may be surfaced to the user in the v0.6 turn-end notice (ADR 0050) and are part of the retrievable memory surface until rejected. Silent auto-stage would force users to curate their own search history after the fact.

Option 2 keeps the trust posture of "Allbert remembers what the user told it to remember" while still delivering the origin-note intent.

## Decision

v0.7 ships option 2. `web_search` and `fetch_url` gain an optional `record_as` parameter:

```json
{
  "name": "web_search",
  "input": {
    "query": "Postgres connection pool settings",
    "record_as": "Postgres pgbouncer recommended default pool sizes"
  }
}
```

When the agent populates `record_as`, the tool result stages a memory entry with:

- `kind: research`
- `source_url: <canonical URL>` (from the top-ranked result for `web_search`; directly from the fetched URL for `fetch_url`)
- `summary: <record_as value>`
- `fetched_at: <UTC timestamp>`
- `fingerprint: sha256(summary + source_url)` per ADR 0047 dedup

Without `record_as`, the tools behave exactly as v0.5: return results, do not stage.

### Agent behaviour

The agent is expected to populate `record_as` in response to explicit user phrases like:

- "remember this"
- "save that for later"
- "look that up and save it"
- "add that to what you know about X"

Bootstrap prompts (`SOUL.md`, `TOOLS.md`) reinforce this. Absent such phrases, the agent uses the tools without `record_as`. This is a prompt-level policy, not a hard-coded filter — agents may be wrong sometimes, but the normal kernel surface (turn-end notice in ADR 0050) catches over-eager staging.

### Staging pipeline

Staged `research` entries route through the same machinery as every other staged entry:

- 5-per-turn cap and 90-day TTL (ADR 0047)
- Dedup by fingerprint (ADR 0047)
- Surfaced in the turn-end notice (ADR 0050)
- Promoted via `memory promote <id>` or the curator skill (ADR 0048)

No privileged bypass. `research` is a new `kind` value added to the staged-memory registry; ADR 0047 now explicitly allows additive `kind` extensions without changing the on-disk shape of older entries.

## Consequences

**Positive**

- Delivers the origin-note "learns from searches" intent without privacy landmines.
- Privacy-by-default: a search the user does not ask to remember stays ephemeral.
- Reuses the full staging/promotion pipeline; no new tier, no new UI.
- Composes cleanly with the turn-end notice (ADR 0050) so users see what was captured.

**Negative**

- Recall depends on the agent recognising user intent correctly. A user who says "find me X" without "remember it" gets no stage.
- Users who want aggressive auto-stage must add a skill or hook that does it explicitly (out of scope for this ADR; future skill-authored extension).

**Neutral**

- `research` becomes a first-class staged-memory `kind` alongside the v0.5 baseline kinds from ADR 0047.
- The `record_as` parameter is opt-in per tool call. `web_search` and `fetch_url` remain usable from any skill without coupling to staging.
- Source-URL tracking enables future provenance surfacing (e.g. "I know X because on 2026-04-20 you asked me to remember this article").

## References

- [docs/notes/origin-2026-04-17.md](../notes/origin-2026-04-17.md)
- [ADR 0042](0042-autonomous-learned-memory-writes-go-to-staging-before-promotion.md)
- [ADR 0047](0047-staged-memory-entries-have-a-fixed-schema-and-limits.md)
- [ADR 0050](0050-turn-end-staged-memory-notice-is-kernel-rendered-togglable-suffix.md)
- [docs/plans/v0.7-channel-expansion.md](../plans/v0.7-channel-expansion.md)
