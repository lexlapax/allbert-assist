# ADR 0037: Legacy minimal skills have a one-release compatibility window before strict AgentSkills validation

Date: 2026-04-18
Status: Proposed

## Context

v0.1 and v0.2 shipped skills in a minimal directory shape centered on `~/.allbert/skills/<name>/SKILL.md`. That means Allbert already has the top-level folder convention AgentSkills expects, but those legacy skills may still lack:

- stricter AgentSkills-compatible metadata,
- declared `scripts:` / `references:` resource structure,
- portable validation expectations across the broader skill ecosystem.

v0.4 adopts the full AgentSkills folder format as canonical (ADR 0032). Users and bundled skill authors need a migration story from the relaxed early shape to the stricter canonical one.

Options considered:

1. Keep loading relaxed legacy skills indefinitely alongside strict AgentSkills skills.
2. Load relaxed legacy skills in v0.4 only, with a deprecation warning and a migration helper; require strict AgentSkills validation from v0.5 onward.
3. Force strict AgentSkills validation at the v0.4 upgrade boundary — no relaxed legacy skill loads at all after v0.4 ships.

Option 1 leaves two permanent validation/loader modes and splits the skill-author story forever. Option 3 is a hard break that strands any bundled or user-authored legacy skill the moment v0.4 lands. Option 2 gives one full release cycle to normalize skills, with visible warnings and a helper to automate most of the conversion.

## Decision

v0.4 reads both relaxed legacy skills and strict AgentSkills-format skills. v0.5 removes the relaxed compatibility path.

- On every load of a legacy relaxed skill in v0.4, the skill loader emits a deprecation warning to the console, the trace log, and the skill status output. The warning names the skill and points at the migration helper.
- A bundled migration helper normalizes a relaxed legacy skill into strict AgentSkills form: it preserves `<skill-name>/SKILL.md`, rewrites metadata into the canonical schema where needed, creates `scripts/`, `references/`, `assets/`, and `agents/` directories when relevant, and validates the result against the AgentSkills schema.
- The migration helper runs in preview mode by default; a `--apply` flag writes the normalized skill and either updates the original in place or writes to a sibling output path, as the user chooses.
- Bundled first-party skills ship in strict AgentSkills-compatible form starting v0.4; the migration helper is for user-authored skills and for backwards compatibility with out-of-band skill collections.
- v0.5 removes the relaxed compatibility mode and the deprecation-warning plumbing. Any remaining relaxed legacy skill fails strict validation with an actionable error pointing at the migration helper (which stays available).

## Consequences

**Positive**
- Gives users one full release cycle to normalize skills with visible warnings.
- Automates the common case of conversion so migration is not a burden.
- Keeps the eventual code paths simple — one loader, one skill shape, after v0.5.

**Negative**
- v0.4 carries relaxed and strict validation paths plus a warning surface.
- Users who skip v0.4 and upgrade straight to v0.5 must run the migration helper before skills will load.

**Neutral**
- The deprecation-warning surface itself can be reused for future format migrations.
- The migration helper can stay shipped past v0.5 as a one-shot conversion utility.

## References

- [ADR 0002](0002-skill-bodies-require-explicit-activation.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [docs/plans/v0.4-agentskills-adoption.md](../plans/v0.4-agentskills-adoption.md)
- [docs/plans/v0.5-curated-memory.md](../plans/v0.5-curated-memory.md)
