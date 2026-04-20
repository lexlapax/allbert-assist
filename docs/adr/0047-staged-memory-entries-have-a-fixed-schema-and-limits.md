# ADR 0047: Staged memory entries have a fixed schema and rate/size/TTL limits

Date: 2026-04-20
Status: Accepted

## Context

Staging (ADR 0042) is where autonomous learned memory lands before operator review. For staging to be a durable review surface rather than a rapidly-blown-out queue, v0.5 needs an explicit contract for what a staged entry looks like on disk and what limits prevent the queue from growing unboundedly.

Without these rules, three foreseeable failure modes materialize:

- chatty agents leave thousands of near-duplicate staged entries that drown the review signal;
- staged entries written by different code paths have inconsistent metadata, making attribution unreliable;
- old unreviewed entries accumulate forever and leak into prompt-native review summaries long after they stopped being relevant.

## Decision

Staged entries follow a fixed on-disk schema and hard runtime limits.

### File naming

Staged entries are individual markdown files under `~/.allbert/memory/staging/`, named:

```
YYYYMMDDTHHMMSSZ-<8-hex-char-hash>.md
```

The timestamp is UTC; the hash is derived from the entry's `id` (see below) to keep file listings alphabetically recency-ordered without breaking on clock skew. The `.md` extension is mandatory so operators can read or edit files with any markdown tool.

### Frontmatter schema

Each staged entry begins with a YAML frontmatter block with these fields. All keys are required unless marked optional.

```yaml
---
id: stg_01HXY4P8M3N2V9T5Q6W7R8E9A0          # ULID-ish opaque id; stable across moves
agent: <root | skill/<skill>/<agent>>         # who authored the entry
session_id: <session uuid>                    # which session produced it
turn_id: <turn-local counter or uuid>         # which turn in that session
kind: explicit_request                        # enum below
summary: <single-line human summary>          # required, <= 240 chars
source: channel|job|cli|subagent              # how the turn was initiated
provenance:                                   # optional; free-form but structured
  prompt_excerpt: "<<short snippet>>"
  skill: <skill name if applicable>
  subagent_of: <parent agent name if applicable>
tags: [postgres, config]                      # optional; lowercased, deduped
fingerprint: sha256:<hex>                     # content dedup fingerprint
created_at: 2026-04-20T14:23:11Z              # ISO-8601 UTC
expires_at: 2026-07-19T14:23:11Z              # created_at + staged_entry_ttl_days
---
```

`kind` is one of:

- `explicit_request` — the user asked to remember something.
- `learned_fact` — the agent inferred a durable fact worth remembering.
- `job_summary` — a scheduled job's output.
- `subagent_result` — a sub-agent contributed a candidate learning.
- `curator_extraction` — the `memory-curator` skill's explicit extraction agent ran.

The body (below the frontmatter) is the candidate memory content rendered as markdown. No binary attachments.

### Dedup fingerprint

`fingerprint` is `sha256(normalized_body)` where `normalized_body` is the markdown body with whitespace collapsed and case folded. On `stage_memory`:

- if a staging entry with the same `fingerprint` already exists and is younger than `memory.staged_entry_ttl_days`, the new stage is rejected with a `StagingDuplicate` hook event instead of writing a second file;
- if an entry with the same fingerprint exists in `notes/` (via the manifest's body hashes), the stage is rejected with a `StagingAlreadyDurable` hook event.

### Limits

All enforced by the kernel at stage time or by the bootstrap TTL sweep:

| Limit | Default | Behavior on violation |
| --- | --- | --- |
| `max_staged_entries_per_turn` | 5 | additional stages in the same turn fail with `StagingTurnCapExceeded` hook event |
| `staged_total_cap` | 500 | new stages fail with `StagingGlobalCapExceeded`; CLI and curator skill surface an actionable message |
| `staged_entry_ttl_days` | 90 | entries past TTL move to `staging/.expired/` at bootstrap and on each midnight job tick |
| max body bytes | 16 KiB | oversized stages truncate with a visible `[truncated]` marker and a `StagingBodyTruncated` hook event |

Rejected entries move to `staging/.rejected/YYYYMMDDTHHMMSSZ-<id>.md` with a `rejection` frontmatter block (reason, rejected_at). `.rejected/` is retained for `rejected_retention_days` (default 30).

## Consequences

**Positive**

- Staged entries are consistently attributable and easy to browse, diff, or script against.
- Duplicate detection keeps the review queue meaningful over long-lived daemon sessions.
- TTL and caps prevent the silent staging blowup that would otherwise follow from chatty agents or frequent jobs.
- Operators can edit, move, or delete staged markdown with regular tools without breaking the kernel.

**Negative**

- The schema is rigid; future fields must be added with a frontmatter migration or tolerated as unknown keys.
- Fingerprint-based dedup occasionally rejects legitimate re-stagings that happen to share normalized text.

**Neutral**

- Future releases can change the dedup algorithm (e.g. semantic hashing) as long as the frontmatter field stays named `fingerprint`.
- `.expired/` and `.rejected/` directories are explicitly retained for operator recovery, not treated as silent garbage.

## References

- [docs/plans/v0.5-curated-memory.md](../plans/v0.5-curated-memory.md)
- [ADR 0042](0042-autonomous-learned-memory-writes-go-to-staging-before-promotion.md)
- [ADR 0046](0046-v0-5-memory-retrieval-uses-tantivy.md)
