# ADR 0044: Sub-agents receive filtered memory context, not full parent recall

Date: 2026-04-20
Status: Accepted

## Context

By v0.3, Allbert already has first-class sub-agents. Once curated retrieval exists, there is a tempting but dangerous default: give every spawned sub-agent the same retrieved memory payload the root agent received.

That creates two problems:

- it leaks more context than the sub-task needs;
- it makes memory growth scale poorly as delegation increases.

Sub-agents need a memory rule, not just a spawn rule.

## Decision

Sub-agents in v0.5 receive filtered memory context.

They get:

- the bootstrap bundle
- `AGENTS.md`
- the parent-provided task brief
- a filtered memory slice selected for the sub-task
- their own ephemeral working-memory state

They do **not** inherit the full parent retrieved-memory set by default.

If allowed by policy, they may explicitly call `search_memory` or `read_memory`.

Candidate learnings from sub-agents follow the same staging rule as root-agent learnings and carry sub-agent attribution.

## Consequences

**Positive**

- Delegation stays bounded and less noisy.
- The root agent remains the main place where broader memory context is assembled.
- Memory cost and prompt size scale more sanely with sub-agent use.

**Negative**

- Some sub-agents may need an explicit extra search when the filtered slice is not enough.

**Neutral**

- The exact filtering heuristic can evolve later without changing the default contract.

## References

- [docs/plans/v0.05-curated-memory.md](../plans/v0.05-curated-memory.md)
- [ADR 0029](0029-agents-are-first-class-runtime-participants.md)
- [ADR 0031](0031-skills-can-contribute-agents-via-frontmatter.md)
