# ADR 0032: AgentSkills folder format is the canonical skill shape

Date: 2026-04-18
Status: Proposed

## Context

v0.1 and v0.2 shipped skills as minimal directories centered on `SKILL.md` with YAML frontmatter. That shape already matched the top-level `skill-name/SKILL.md` convention, but it was a relaxed subset of the fuller AgentSkills shape and it limits three things:

1. Skills with supporting scripts have nowhere to put them cleanly.
2. Reference material (docs, prompt excerpts) lives either inline (bloating every load) or out-of-band (breaking portability).
3. Allbert cannot trivially share skills with the broader agent-assistant ecosystem.

The AgentSkills open standard at [agentskills.io](https://agentskills.io/home) already defines a richer shape: `skill-name/SKILL.md` plus optional `scripts/`, `references/`, and `assets/` directories, with a defined frontmatter schema (required: `name` kebab-case ≤64 chars and `description` ≤1024 chars; optional: `license`, `compatibility`, `metadata`, `allowed-tools`). Progressive disclosure surfaces metadata, body, and linked resources at increasing depth. A `skills-ref` CLI exists for validation.

Options considered:

1. Stay on the minimal `SKILL.md`-only shape and add more frontmatter fields ad hoc.
2. Invent a third Allbert-specific format.
3. Adopt the AgentSkills folder format as canonical, with a one-release relaxed-compatibility window for existing minimal skills (ADR 0037) and a migration helper.

Option 3 aligns Allbert with an emerging open standard, gives scripts and references proper homes, and enables progressive disclosure as a principled feature rather than an ad hoc optimisation.

## Decision

v0.4 adopts the AgentSkills folder format as the canonical skill shape.

- A skill is a directory `<skill-name>/` containing `SKILL.md` and optional `scripts/`, `references/`, `assets/` subdirectories.
- The directory name is the canonical skill name; it must be kebab-case, unique, and stable, and it must match the `name` field in frontmatter.
- `SKILL.md` has YAML frontmatter followed by a markdown body. Required fields: `name`, `description`. Optional: `license`, `compatibility`, `metadata`, `allowed-tools`, plus Allbert extensions (`agents`, `bundles`).
- Skill-local references are addressable as `references/<file>` within the skill; links in the body use relative paths.
- Skill-local scripts are declared in frontmatter under `scripts:` and invoked through the kernel exec seam (ADR 0034).
- Validation uses an Allbert-internal validator that is compatible with the `skills-ref` schema; skills that pass upstream validation pass Allbert validation as long as no Allbert extensions are misused.
- Legacy minimal skills continue to load through v0.4 only, with a deprecation warning and a bundled migration helper. The relaxed compatibility path is removed in v0.5 (ADR 0037).

## Consequences

**Positive**
- Allbert can read, install, and share skills authored for any AgentSkills-compatible agent runtime.
- Separates prompt body from scripts and references cleanly; supports progressive disclosure (ADR 0036).
- Gives skill authors a clear, documented file layout.

**Negative**
- Breaking change for legacy minimal skills after one release; users must normalize them.
- Skill loader gains directory-walking, validation, and resource resolution logic.

**Neutral**
- Future upstream AgentSkills changes are tracked as updates against this decision.
- Allbert-specific extensions remain opt-in frontmatter fields so round-tripping with the wider ecosystem stays clean.

## References

- [ADR 0002](0002-skill-bodies-require-explicit-activation.md)
- [ADR 0008](0008-skill-allowed-tools-is-a-fence-not-a-sandbox.md)
- [ADR 0031](0031-skills-can-contribute-agents-via-frontmatter.md)
- [ADR 0036](0036-progressive-disclosure-maps-to-prompt-construction-stages.md)
- [ADR 0037](0037-single-file-skills-have-a-one-release-read-path-then-are-removed.md)
- [docs/plans/v0.4-agentskills-adoption.md](../plans/v0.4-agentskills-adoption.md)
- [agentskills.io](https://agentskills.io/home)
