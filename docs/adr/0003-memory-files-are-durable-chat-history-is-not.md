# ADR 0003: Memory files are durable; chat history is not

Date: 2026-04-17
Status: Accepted

## Context

[`docs/vision.md`](../vision.md) emphasizes markdown files "for posterity and transference." That implies durable state should be legible, portable, and intentionally curated rather than trapped in opaque runtime history. A competing option would be to persist chat transcripts and let those transcripts become de facto memory.

The problem with durable chat history is that it creates two overlapping long-term stores:
- explicit memory files
- implicit conversation logs

Once both exist, the system can begin depending on invisible old context instead of writing down important facts in a place the user can inspect and move to another system.

## Decision

Session message history is ephemeral runtime scratch space. Durable state belongs in markdown memory files.

- Each kernel session starts with a fresh in-memory conversation state.
- Long-term facts, notes, and decisions are persisted under the memory directory, not in hidden chat transcripts.
- Prompt injection of memory is intentional and bounded: the model gets a small memory index and recent daily context, then pulls more specific files explicitly when needed.

This preserves a single durable memory model for v0.1.

## Consequences

**Positive**
- Durable knowledge remains inspectable, editable, and portable.
- The assistant is encouraged to write down facts worth keeping.
- Memory architecture stays legible early, before retrieval becomes more sophisticated.

**Negative**
- Restarting a session loses conversational scratch context unless the model saved it intentionally.
- Some UX may feel less continuous than products that silently persist chat logs forever.

**Neutral**
- Cost logs and traces can still persist independently; they are operational records, not memory.
- Future versions may add optional persisted conversations, but only as a distinct subsystem.

## References

- [docs/vision.md](../vision.md)
- [docs/plans/v0.1-mvp.md](../plans/v0.1-mvp.md)
