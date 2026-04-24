# ADR 0048: v0.5 ships a first-party memory-curator skill

Date: 2026-04-20
Status: Accepted

## Context

v0.5 introduces curated memory with explicit staging before promotion (ADR 0042) and defines prompt-native and CLI review surfaces in the plan. That leaves a question of packaging: should Allbert ship its own memory-curation skill, vendor an existing community skill, or leave the review workflow as kernel-only behavior?

A survey of existing open-source skills was conducted in April 2026 against:

- [skillsmp.com](https://skillsmp.com)
- [mcpmarket.com/tools/skills](https://mcpmarket.com/tools/skills)
- [github.com/VoltAgent/awesome-openclaw-skills](https://github.com/VoltAgent/awesome-openclaw-skills)

The closest conceptual matches were `xiaowenzhou/active-maintenance`, `agent-memory-ultimate`, `memory-hygiene` (all in the openclaw ecosystem), and MCP-style tools such as `memory-health-dashboard`. Each was disqualified for at least one of these reasons:

- **Storage assumption mismatch.** `agent-memory-ultimate` uses SQLite + FTS5 + embeddings; `memory-hygiene` targets a LanceDB vector store. Both are architecturally incompatible with Allbert's markdown-first tier model (ADR 0040) and its derived-index rule (ADR 0045).
- **License uncertainty.** Several candidates lack a clearly declared permissive license at the subfolder level, making vendoring risky.
- **Parent-repo security posture.** The `openclaw/skills` repository carries an explicit disclaimer that it may contain suspicious or malicious skills. Under Allbert's install trust model (ADR 0033), vendoring from that source would require a full audit per skill; the cost outweighs the benefit for a small reference skill.
- **Bundled unaudited scripts.** Candidates like `active-maintenance` ship Python scripts that cross-cut unrelated concerns (temp-dir cleanup, decay functions). Importing them whole into our exec-policy envelope (ADR 0034) is more risk than it is worth.
- **MCP vs AgentSkills shape.** Some candidates (e.g. `memory-health-dashboard`) are MCP tools, not AgentSkills-format folders, and would not slot into the v0.4 skill install path.

Leaving curation as kernel-only behavior was rejected because the prompt-native review flow deserves to live outside the kernel — it is a workflow, not a runtime primitive — and because a thin curator skill is the natural reference implementation for the broader memory-aware skill seam the plan opens up.

## Decision

v0.5 ships a first-party `memory-curator` skill as part of the shipped skill bundle.

- **Path:** `skills/memory-curator/` in the repo; installed under `~/.allbert/skills/installed/memory-curator/` on fresh profiles.
- **Format:** canonical AgentSkills folder (ADR 0032) — `SKILL.md` plus any reference docs. No bundled scripts.
- **Capabilities:**
  - guided review of staged entries (`list_staged_memory`, `search_memory(tier = "staging")`, `read_memory`);
  - duplicate detection assistance against the durable corpus;
  - batch promotion that routes each promotion through the operator's `confirm-trust` surface;
  - suggested compaction of long-running daily notes into durable notes;
  - an optional `curator.extract_from_turn` agent entrypoint that the operator can invoke explicitly to run an LLM-backed extraction pass over the current turn.
- **Security posture:**
  - no network calls;
  - no process execution;
  - no filesystem access outside `~/.allbert/memory/`;
  - every durable-memory mutation goes through an existing memory tool (`promote_staged_memory`, `reject_staged_memory`, `write_memory`), not around them;
  - LLM usage by the extraction agent is accounted to the active session's cost record, per the normal cost-tracking surface.
- **Post-turn extraction stays opt-in.** The kernel's turn loop only stages via explicit `stage_memory` calls from agents during the turn (per the v0.5 plan's Memory write policy). Any LLM-backed "look at this turn and suggest things to remember" work happens inside this skill, not inside the kernel.

This skill is the reference for what a memory-aware community skill looks like: small, prompt-only, narrow in capability, and composed out of kernel memory tools rather than adjacent runtime seams.

## Consequences

**Positive**

- Operators get a prompt-native review UX in v0.5 without the kernel taking on workflow logic.
- No third-party dependency, no license ambiguity, no audit burden from a foreign codebase.
- Future community skills have a concrete reference to fork.

**Negative**

- Allbert now owns another skill in its release surface; changes to staging schema or memory tools must keep the curator skill working.
- The curator's review UX is our responsibility to iterate on; there is no upstream to track.

**Neutral**

- If a compelling external memory-curator skill lands later (markdown-first, permissive license, clean audit), it can be installed alongside or replace ours without any kernel change.
- The curator's extraction agent lives in userland; its prompt can evolve independently of the kernel.

## References

- [docs/plans/v0.05-curated-memory.md](../plans/v0.05-curated-memory.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0040](0040-curated-memory-has-identity-durable-staging-and-ephemeral-tiers.md)
- [ADR 0042](0042-autonomous-learned-memory-writes-go-to-staging-before-promotion.md)
- [ADR 0047](0047-staged-memory-entries-have-a-fixed-schema-and-limits.md)
