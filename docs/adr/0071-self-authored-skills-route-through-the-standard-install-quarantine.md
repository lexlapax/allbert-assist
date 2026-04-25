# ADR 0071: Self-authored skills route through the standard install quarantine

Date: 2026-04-23
Status: Accepted

Amends: [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)

## Context

The v0.12 skill-authoring skill (`skill-author`, ADR 0072) lets a user describe a skill in natural language and have Allbert produce an AgentSkills folder for it. That capability needs a clear answer to two questions:

1. **Where do drafts go?** A draft skill is by definition not yet trusted. Writing it directly into `~/.allbert/skills/installed/` would bypass the install gate (ADR 0033) — which exists exactly to keep untrusted skill content out of the active skills root.
2. **How does the operator tell self-authored skills apart from external installs?** Trust posture is identical (both go through preview + confirm), but for review and audit purposes the operator should be able to see at a glance "did Allbert write this, or did it come from a git URL?"

There is also a third, subtler concern. The kernel already has a `create_skill` tool (used internally for first-party seeding). If `skill-author` calls `create_skill` directly, it would write to `installed/` and skip the install preview. That is the wrong default for any caller that is operating on user intent rather than first-party setup.

The cleanest design is to reuse the existing quarantine path (`~/.allbert/skills/incoming/` per ADR 0033) and add a single frontmatter field that records origin. The install gate stays where it is; `skill-author` is just one more producer that hands a candidate skill to the gate.

## Decision

Self-authored skills route through the same install quarantine as any other source. ADR 0032 is amended to add a `provenance` frontmatter field that records the origin.

### Quarantine path

`skill-author` writes draft skills to `~/.allbert/skills/incoming/<draft-name>/`. This is the same directory ADR 0033 already uses for git/path installs. The skill-authoring skill does not invent a new draft directory.

Iterative drafts persist across turns and survive session exit. The drafts directory IS the standard quarantine path; if the operator opens a fresh session and asks "what skills are pending review?", `skill-author`'s in-progress drafts appear alongside any external installs.

### `provenance` frontmatter field

ADR 0032's optional frontmatter list gains:

```yaml
provenance: external | local-path | git | self-authored
```

Defaults and meanings:

| Value | When set | Source |
| --- | --- | --- |
| `external` | Default for any skill loaded without an explicit provenance value. Existing v0.4–v0.10 skills load as `external`. | Backwards-compat default. |
| `local-path` | Skill installed from a local filesystem path. | Set by the install flow when the source is a local path. |
| `git` | Skill installed from a git URL + ref. | Set by the install flow when the source is a git remote. |
| `self-authored` | Skill produced by `skill-author` (or by any future authoring skill). | Set by `skill-author` when writing the draft. |

Validation is additive. Skills without the field load as `external` — no migration is required for installed content.

### Provenance persists on promotion

When a skill is promoted from `incoming/<name>/` to `installed/<name>/` (the install confirm step), the `provenance` field travels unchanged. A `self-authored` skill stays `self-authored` after install; the operator cannot accidentally relabel it as external by re-installing.

### Surfaces that show provenance

- `allbert-cli skills list` adds a `Source` column showing the provenance tag.
- Install preview (ADR 0033) surfaces `provenance` alongside `name`, `description`, and `allowed-tools`.
- The skill loader logs provenance at activation time.

Trust posture is **not** changed. A `self-authored` skill goes through preview + confirm just like an `external` one. The provenance field is observability, not policy.

### `create_skill` hardening

The existing `create_skill` kernel tool gains a required argument:

```
create_skill(..., skip_quarantine: bool)
```

Behavior:

- `skip_quarantine: true` — preserves the existing behavior (writes to `installed/`). Reserved for first-party kernel seeding (e.g. shipping `memory-curator` on first run). Prompt-originated tool calls cannot use it. The boolean is recorded in hook metadata for audit.
- `skip_quarantine: false` — writes to `incoming/`, emits an install-preview event, and the skill goes through the standard confirm flow. This is what `skill-author` uses.

There is no default value. Callers must state their intent. `allowed-tools` still names tools only; it does not express parameter-level policy. `skill-author` may list `create_skill`, but the kernel `create_skill` handler denies `skip_quarantine: true` for prompt-originated or active-skill calls.

### Why amend ADR 0032 rather than write a new ADR for the field

The field is structurally an addition to ADR 0032's frontmatter contract. A separate ADR would create a confusing two-place definition where someone reading ADR 0032 would not learn about the field. Amending ADR 0032 (with a banner pointing at this ADR) keeps the canonical frontmatter list in one place.

## Consequences

**Positive**

- Self-authored skills cannot bypass the install gate. The trust contract is identical to any other source.
- Operators can audit and filter self-authored content from a single column in `skills list`.
- `create_skill` hardening removes an existing latent footgun: a skill that called `create_skill` could have written to `installed/` and skipped preview. The required boolean makes the call site explicit.
- Provenance survives promotion; cannot be silently relabeled.

**Negative**

- Existing callers of `create_skill` must be updated to pass `skip_quarantine: true` (the previous implicit behavior). This is a one-time mechanical change in the kernel and any first-party seeding code.
- Skills missing the `provenance` field load as `external`, which is the safe default but technically a tiny information loss for older skills installed before v0.12.

**Neutral**

- ADR 0032 gains an amendment banner pointing at this ADR. Future readers see the pointer and can find the new field in one hop.
- Future provenance values (e.g. `registry` for ADR 0035's deferred curated registry) slot in alongside the existing four without needing another amendment.

## References

- [docs/plans/v0.12-self-improvement.md](../plans/v0.12-self-improvement.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md) — amended by this ADR (adds `provenance` field).
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0035](0035-remote-skill-registry-is-deferred-v0-4-sources-are-local-path-and-git-url.md)
- [ADR 0048](0048-v0-5-ships-a-first-party-memory-curator-skill.md)
- [ADR 0072](0072-skill-authoring-is-a-first-party-natural-language-skill.md)
