# ADR 0039: AGENTS.md joins the bootstrap bundle in v0.3

Date: 2026-04-18
Status: Proposed

## Context

ADR 0010 established the bootstrap bundle — `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, and optional `BOOTSTRAP.md` — as first-class kernel-owned prompt context. At the time, ADR 0010 explicitly declined to adopt `AGENTS.md` or `HEARTBEAT.md`: "Those can be reconsidered later when Allbert has broader session surfaces, proactive jobs, or group-chat behavior that makes them pull their weight."

Those preconditions are now met. v0.2 shipped proactive jobs (ADR 0022). v0.3 makes agents first-class runtime participants (ADR 0029) and lets skills contribute new agents through frontmatter (ADR 0031). Without a kernel-owned `AGENTS.md`, users would have to discover the available agent roster by running CLI introspection commands, which works but is not the shape the rest of the bootstrap layer takes.

The bootstrap layer is also the main place ADR 0038's "natural interface" principle shows up concretely: it is the markdown surface a user reads and edits. Adding `AGENTS.md` extends that surface in a way that is consistent with how `SOUL.md` and `TOOLS.md` already work.

Options considered:

1. Keep the agent roster purely as runtime state, discoverable through `allbert-cli agents list`. Users read commands, not files.
2. Make `AGENTS.md` a user-editable markdown file, like `SOUL.md`. Users can write custom agent definitions directly.
3. Make `AGENTS.md` a kernel-maintained bootstrap file. The kernel regenerates it whenever skills are installed, removed, or updated. Users read it for reference and can cite agent names in prompts, but edits go through the skill install/remove flow.

Option 1 keeps the roster invisible to the prompt layer. Option 2 would give users an extra authoring path that duplicates skill frontmatter — the v0.3 contract is that agents are *contributed by skills* (ADR 0031), not authored standalone in a top-level file. Option 3 honours ADR 0031's single authoring surface while still giving users an inspectable markdown index.

`HEARTBEAT.md` (the other file ADR 0010 deferred) is a separate question tied to async channel rhythms. v0.6 channel expansion is the right time to reopen it, not v0.3.

## Decision

`AGENTS.md` joins the bootstrap bundle in v0.3 as a kernel-maintained file.

- Location: `~/.allbert/AGENTS.md`, alongside `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`.
- **Ownership**: kernel-owned. The kernel regenerates `AGENTS.md` whenever skills are installed, removed, or updated, and on daemon startup if it is missing.
- **Content**: one section for the root agent (`allbert/root`) plus one section per skill-contributed agent (namespaced `<skill>/<agent>`). Each entry lists:
  - the agent's namespaced name,
  - its one-line description,
  - its `allowed-tools` summary (intersected with the session envelope),
  - the contributing skill (for contributed agents),
  - the optional model override, if declared.
- **User edits**: the file is read-only from the user's perspective. A leading comment in the file states that direct edits will be overwritten on the next regeneration, and points to `allbert-cli skills install/remove` as the authoring path.
- **Prompt inclusion**: like other bootstrap files, `AGENTS.md` is snapshotted at the start of each user turn and injected ahead of memory and skills, bounded by the same kind of dedicated budget ADR 0010 defined for the original bundle.
- **Scope**: v0.3 only. `HEARTBEAT.md` remains deferred until v0.6 channel expansion considers it.

## Consequences

**Positive**
- Gives users an inspectable, natural-language view of every agent available in the current session, consistent with ADR 0038's natural-interface principle.
- Lets a user cite contributed agents by name in prompts ("ask the `research/reader` agent to summarise this page") without needing to memorise them.
- Reuses the bootstrap prompt pipeline ADR 0010 already established — no new runtime machinery needed.

**Negative**
- Kernel must keep `AGENTS.md` fresh across skill lifecycle events; a stale file could mislead users.
- One more file contributes to the bootstrap prompt budget. The file is short and regenerated, so the impact should be bounded.

**Neutral**
- `HEARTBEAT.md` remains deferred to v0.6.
- User-authored agent definitions still flow through skill frontmatter (ADR 0031), preserving a single authoring path.
- A future release could expose per-agent enabled/disabled state in this file once agent-level activation becomes user-facing.

## References

- [ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md)
- [ADR 0022](0022-job-definitions-are-markdown-with-frontmatter-and-a-bounded-schedule-dsl.md)
- [ADR 0029](0029-agents-are-first-class-runtime-participants.md)
- [ADR 0031](0031-skills-can-contribute-agents-via-frontmatter.md)
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md)
- [docs/plans/v0.3-agent-harness.md](../plans/v0.3-agent-harness.md)
