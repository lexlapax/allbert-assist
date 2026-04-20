# ADR 0037: Single-file skills have a one-release read path, then are removed

Date: 2026-04-18
Status: Proposed

## Context

v0.1 and v0.2 shipped skills as single markdown files. v0.4 adopts the AgentSkills folder format as canonical (ADR 0032). Users and bundled skill authors need a migration story.

Options considered:

1. Keep loading single-file skills indefinitely alongside folder skills.
2. Load single-file skills in v0.4 only, with a deprecation warning and a migration helper; drop the read path in v0.5.
3. Force migration at the v0.4 upgrade boundary — no single-file skills load at all after v0.4 ships.

Option 1 leaves two permanent loader code paths and splits the skill-author story forever. Option 3 is a hard break that strands any bundled or user-authored single-file skill the moment v0.4 lands. Option 2 gives one full release cycle to migrate, with visible warnings and a helper to automate most of the conversion.

## Decision

v0.4 reads both single-file and folder-format skills. v0.5 removes the single-file read path.

- On every load of a single-file skill in v0.4, the skill loader emits a deprecation warning to the console, the trace log, and the skill status output. The warning names the skill and points at the migration helper.
- A bundled migration helper converts a single-file skill into the folder format: it creates `<skill-name>/SKILL.md`, moves the existing frontmatter and body across, adds empty `scripts/` and `references/` directories where relevant, and validates the result against the AgentSkills schema.
- The migration helper runs in preview mode by default; a `--apply` flag writes the converted skill and either removes the original file or leaves it in place for user cleanup, as the user chooses.
- Bundled first-party skills ship in folder format starting v0.4; the migration helper is for user-authored skills and for backwards compatibility with out-of-band skill collections.
- v0.5 removes the single-file loader and the deprecation warning plumbing. Any remaining single-file skill fails to load with an actionable error pointing at the migration helper (which stays available).

## Consequences

**Positive**
- Gives users one full release cycle to migrate with visible warnings.
- Automates the common case of conversion so migration is not a burden.
- Keeps the eventual code paths simple — one loader, one skill shape, after v0.5.

**Negative**
- v0.4 carries two loader code paths and a warning surface.
- Users who skip v0.4 and upgrade straight to v0.5 must run the migration helper before skills will load.

**Neutral**
- The deprecation-warning surface itself can be reused for future format migrations.
- The migration helper can stay shipped past v0.5 as a one-shot conversion utility.

## References

- [ADR 0002](0002-skill-bodies-require-explicit-activation.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [docs/plans/v0.4-agentskills-adoption.md](../plans/v0.4-agentskills-adoption.md)
- [docs/plans/v0.5-curated-memory.md](../plans/v0.5-curated-memory.md)
