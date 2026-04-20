# ADR 0031: Skills can contribute agents via frontmatter

Date: 2026-04-18
Status: Proposed

## Context

ADR 0029 makes agents first-class, but the ADR does not say who is allowed to define new agents. Two options:

1. Only kernel-internal code or bundled templates can register agents. Skill-authored agents would require an out-of-band PR to the runtime.
2. Skills can declare agent contributions in their frontmatter, and the kernel resolves them at skill-load time.

Option 2 matches the skill-first philosophy already in place: skills already contribute prompts (ADR 0002) and tool fences (ADR 0008). Agents are the natural next seam for skills to contribute.

## Decision

Skills may declare `agents:` in their frontmatter. Each entry points to a skill-local markdown file (typically `agents/<name>.md` within the skill folder once v0.4 lands the folder format, or an adjacent markdown file in the single-file era).

- Each agent file has its own frontmatter declaring `name`, `description`, `allowed-tools`, and an optional `model` override. The body is the agent's system prompt.
- Registered agent names are namespaced as `<skill-name>/<agent-name>` to avoid collisions across skills.
- The skill store registers contributed agents when the skill is loaded and deregisters them when the skill is removed or deactivated. Agent identifiers do not outlive their contributing skill.
- The `allowed-tools` on a contributed agent intersects with the session's global policy envelope; skills cannot grant themselves broader tool access than the session already has (ADR 0008).
- Contributed agents can only be spawned, not treated as root agents in v0.3. The root agent remains the kernel-provided default.

## Consequences

**Positive**
- Keeps skills the primary extension surface.
- Avoids a split-brain registry of "kernel agents" vs "skill agents."
- Removes agent bookkeeping from the kernel's hot path — it lives in the skill store already.

**Negative**
- Skill loader must parse and validate agent frontmatter; a lifecycle bug could leave phantom registrations.
- Namespacing is syntactic; users must be able to address contributed agents clearly in prompts and CLI.

**Neutral**
- A future central agent catalog could coexist with skill-contributed agents without changing this decision.
- Prompt-authored and scheduled jobs can target contributed agents by namespaced name.

## References

- [ADR 0002](0002-skill-bodies-require-explicit-activation.md)
- [ADR 0008](0008-skill-allowed-tools-is-a-fence-not-a-sandbox.md)
- [ADR 0021](0021-kernel-multiplexes-sessions-shared-runtime-per-session-state.md)
- [ADR 0029](0029-agents-are-first-class-runtime-participants.md)
- [docs/plans/v0.3-agent-harness.md](../plans/v0.3-agent-harness.md)
