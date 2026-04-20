# ADR 0037: v0.4 performs a clean cutover to strict AgentSkills skill trees

Date: 2026-04-18
Status: Proposed

## Context

v0.1 through v0.3 shipped skills in a relaxed directory shape centered on `~/.allbert/skills/<name>/SKILL.md`. That earlier shape already shared the top-level folder convention with AgentSkills, but it did not require the stricter validation and layout discipline v0.4 now wants to make canonical.

For v0.4, we considered two broad migration approaches:

1. Carry a runtime compatibility bridge for one or more releases, with dual loader modes, deprecation warnings, and a migration helper.
2. Normalize the shipped skills to strict AgentSkills format as part of the release work, and make the strict format the only v0.4 target.

The first approach reduces immediate breakage for ad hoc legacy skills, but it permanently complicates the loader, test surface, and user story around what a "real" v0.4 skill is. The second approach is a sharper cutover, but it keeps the runtime and docs honest: the system loads one canonical format, and the shipped skills demonstrate that exact format.

## Decision

v0.4 uses a clean cutover to strict AgentSkills-compatible skill trees.

- The shipped first-party and example skills are normalized in-repo to the strict v0.4 folder format before release.
- The canonical active runtime shape is the strict AgentSkills folder layout rooted at the installed skills directory.
- `incoming/` remains quarantine-only and is never part of the active skill load path.
- v0.4 does not introduce a runtime migration helper, dual-root compatibility loader, or deprecation-warning subsystem for legacy minimal skills.
- `allbert-cli skills validate <path>` remains the explicit preflight tool for checking whether a skill tree is already valid before install.

## Consequences

**Positive**
- The runtime, docs, and tests all target one skill shape.
- M5 can focus on normalizing the shipped skills and proving they work, instead of shipping bridge code that will be deleted later.
- End users see the same format in examples, bundled skills, installed skills, and validator output.

**Negative**
- Out-of-band skills that still use the older relaxed shape must be normalized by their authors or operators before they are expected to validate/install cleanly under the v0.4 contract.
- There is no built-in "fix my old skill for me" helper in v0.4.

**Neutral**
- This ADR is intentionally narrower than a general cross-release compatibility policy. Future format changes may choose a different migration strategy if the tradeoffs differ.

## References

- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [docs/plans/v0.4-agentskills-adoption.md](../plans/v0.4-agentskills-adoption.md)
