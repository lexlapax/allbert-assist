# ADR 0040: Curated memory has identity, durable, staging, and ephemeral tiers

Date: 2026-04-20
Status: Accepted

## Context

By the end of v0.4, Allbert already has three distinct kinds of state in practice:

- bootstrap identity files (`SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, `AGENTS.md`)
- durable markdown memory files
- in-memory session state

What it still lacks is an explicit contract for staged learnings and session working memory. Without that contract, any richer memory work risks collapsing multiple concerns into one vague "memory" bucket:

- always-on identity
- approved long-term memory
- candidate learnings
- per-session scratch state

That would make prompt construction, agent context, and operator review much harder to reason about.

## Decision

Curated memory in v0.5 is split into four tiers:

1. **Identity**
   - bootstrap bundle and `AGENTS.md`
   - durable
   - always loaded
2. **Durable**
   - approved long-term memory corpus
   - markdown ground truth under the memory directory
   - searchable and explicitly readable
3. **Staging**
   - candidate learnings awaiting review
   - durable until reviewed
   - not auto-injected as approved memory
4. **Ephemeral**
   - session-scoped working memory
   - in-memory only in v0.5
   - survives detach/reattach but not daemon restart

The tiers are not interchangeable:

- identity is not learned memory
- staging is not approved durable memory
- ephemeral state is not durable memory

## Consequences

**Positive**

- Prompt construction can stay bounded and explicit.
- Durable memory stays inspectable and reviewable.
- The daemon gets a real working-memory layer without inventing hidden long-term transcript memory.
- Later features such as channels and memory-maintenance jobs have a clearer substrate.

**Negative**

- The system must manage more than one memory surface.
- Operators need legible review tools for staging, not just file access.

**Neutral**

- The exact retrieval algorithm can evolve later without changing the four-tier split.
- Future releases may add richer background maintenance, but they still operate within this tier model.

## References

- [docs/plans/v0.5-curated-memory.md](../plans/v0.5-curated-memory.md)
- [ADR 0003](0003-memory-files-are-durable-chat-history-is-not.md)
- [ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md)
- [ADR 0039](0039-agents-md-joins-the-bootstrap-bundle-in-v0-3.md)
