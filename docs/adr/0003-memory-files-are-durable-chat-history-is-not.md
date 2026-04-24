# ADR 0003: Memory files are durable; chat history is not

Date: 2026-04-17
Status: Accepted

> **Amended in part by [ADR 0077](0077-episode-and-fact-memory-are-indexed-recall-not-durable-memory.md) in v0.11**: session journals may be indexed as explicit `episode` recall, but they still are not approved durable memory and cannot bypass staging/promotion.

## Context

[`docs/vision.md`](../vision.md) emphasizes markdown files "for posterity and transference." That implies durable state should be legible, portable, and intentionally curated rather than trapped in opaque runtime history. A competing option would be to persist chat transcripts and let those transcripts become de facto memory.

The problem with durable chat history is that it creates two overlapping long-term stores:
- explicit memory files
- implicit conversation logs

Once both exist, the system can begin depending on invisible old context instead of writing down important facts in a place the user can inspect and move to another system.

## Decision

Session message history is ephemeral runtime scratch space. Durable state belongs in user-editable markdown files, split into bootstrap/profile files and memory files.

- Each kernel session starts with a fresh in-memory conversation state.
- `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, and optional `BOOTSTRAP.md` hold durable runtime identity/profile context.
- Long-term facts, notes, and decisions are persisted under the memory directory, not in hidden chat transcripts.
- Prompt injection of memory is intentional and bounded: the model gets a small always-on memory synopsis and then pulls more specific memory material explicitly or through bounded curated retrieval when needed.
- Future releases may add staging, ranked retrieval, and ephemeral working-memory layers, but those layers still orbit the same rule: markdown files are the durable source of truth and chat transcripts are not.

This preserves a visible durable-state model for v0.1 without making chat transcripts an implicit second memory system.

## Consequences

**Positive**
- Durable knowledge remains inspectable, editable, and portable.
- Durable runtime identity and durable learned memory stay visible and editable in different files instead of collapsing into one hidden blob.
- The assistant is encouraged to write down facts worth keeping.
- Memory architecture stays legible even as retrieval, staging, and ephemeral working memory become more sophisticated.

**Negative**
- Restarting a session loses conversational scratch context unless the model saved it intentionally.
- Some UX may feel less continuous than products that silently persist chat logs forever.

**Neutral**
- Cost logs and traces can still persist independently; they are operational records, not memory.
- Future versions may add optional persisted conversations, but only as a distinct subsystem.

## References

- [docs/vision.md](../vision.md)
- [docs/plans/v0.01-mvp.md](../plans/v0.01-mvp.md)
