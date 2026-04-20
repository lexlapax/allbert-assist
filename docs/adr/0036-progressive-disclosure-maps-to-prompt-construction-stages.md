# ADR 0036: Progressive disclosure maps to prompt construction stages

Date: 2026-04-18
Status: Accepted

## Context

AgentSkills describes progressive disclosure across three tiers:

1. **Discovery tier** — name + description; enough to decide whether the skill is relevant.
2. **Activation tier** — the `SKILL.md` body; loaded once the skill is chosen for a turn.
3. **Resource tier** — linked references, asset files, and scripts; pulled on demand inside the body.

v0.1 and v0.2 loaded skills as a single flat prompt contribution. That worked while skills were small and self-contained. Once Allbert adopts the folder format (ADR 0032), a flat loader would either bloat context by pulling references eagerly or discard the disclosure semantics entirely.

Allbert's prompt builder already has structured stages — bootstrap context, active skills, tool schemas, agent-specific prompt, session conversation. Progressive disclosure fits naturally onto those stages.

## Decision

Allbert's prompt builder surfaces AgentSkills tiers explicitly.

- **Tier 1 — discovery**: `name` and `description` from every installed skill are indexed into a lightweight skill catalog that the intent router (ADR 0030) and skill-selection heuristics can use without loading any `SKILL.md` body. Token cost at this tier is bounded and minimal.
- **Tier 2 — activation**: when a skill is activated for a turn, its `SKILL.md` body (minus reference markers) is loaded into the active-skills prompt stage.
- **Tier 3 — resource**: references, assets, and scripts are resolved on demand. References mentioned in the body become explicit tool calls (e.g. `read_reference(skill, path)`) rather than being inlined; scripts run through the exec seam (ADR 0034).
- The prompt builder emits tier-transition events (`SkillTier1Surfaced`, `SkillTier2Activated`, `SkillTier3Referenced`) so hooks can observe skill depth per turn.
- Tier 1 indexing happens at skill load time and is rebuilt whenever skills are installed, updated, or removed.
- Tier 2 and tier 3 loads are cached per turn; the same reference is not pulled twice in one agent turn.

## Consequences

**Positive**
- Prompt token usage scales with what a turn actually needs, not with how large the skill's reference tree is.
- Keeps skill discovery cheap and robust even when many skills are installed.
- Gives the intent router a clean surface (tier 1 descriptions) without leaking full prompts.

**Negative**
- Prompt builder gains a small new tier-aware loader and a skill catalog.
- Skills must be authored to make tier boundaries meaningful (concise descriptions, focused bodies, references called explicitly).

**Neutral**
- Tier-specific caching (cross-turn) and compression strategies can be layered later without changing this contract.
- Non-Allbert AgentSkills-compatible tools can still consume Allbert-authored skills — tier structure is expressed in the standard file layout.

## References

- [ADR 0002](0002-skill-bodies-require-explicit-activation.md)
- [ADR 0030](0030-intent-routing-is-a-kernel-step-not-a-skill-concern.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [docs/plans/v0.4-agentskills-adoption.md](../plans/v0.4-agentskills-adoption.md)
