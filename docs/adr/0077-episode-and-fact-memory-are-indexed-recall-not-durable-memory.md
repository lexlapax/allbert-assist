# ADR 0077: Episode and fact memory are indexed recall, not hidden durable memory

Date: 2026-04-24
Status: Accepted

## Context

Allbert's memory model is intentionally review-first. ADR 0003 says durable memory is not hidden chat history. ADR 0042 says autonomous learned memory goes to staging before promotion. At the same time, useful agent memory systems point at two capabilities Allbert lacks:

- episode recall: search prior working sessions when the user asks what happened;
- structured temporal facts: track facts with provenance, validity windows, and supersession.

The challenge is adding those capabilities without turning session transcripts or extracted facts into unreviewed durable memory.

## Decision

v0.11 adds two indexed recall surfaces:

1. `episode` search tier, derived from session markdown journals.
2. `fact` search tier, derived from fact metadata in staged/promoted markdown memory.

Episode rules:

- Episodes are derived from `~/.allbert/sessions/*/turns.md`.
- Episode search is explicit by default (`tier = "episode"`).
- Default memory prefetch excludes episodes.
- Forgetting or archiving sessions updates the derived episode index.
- Episode hits are labeled as working history, not approved durable memory.

Fact rules:

- Fact metadata may appear in staged entries and promoted durable notes.
- Staged facts are not approved facts.
- Durable fact search returns facts whose source note is approved durable memory.
- Facts include provenance and may include `valid_from`, `valid_until`, and `supersedes`.
- Superseded facts remain auditable and are excluded from current-fact summaries unless requested.

The markdown file remains the source of truth. The index is derived.

## Consequences

**Positive**

- Allbert can recall prior sessions when explicitly asked.
- Fact memory gets provenance and temporal shape without a separate database.
- Review gates remain intact.
- The system can later support richer memory curation jobs over episodes and facts.

**Negative**

- Operators need clear labels distinguishing durable memory, staged memory, episode history, and facts.
- The indexer becomes broader because it reads session journals as well as memory markdown.

**Neutral**

- Episode/fact retrieval can later participate in automatic prefetch behind explicit config, but v0.11 defaults remain conservative.

## References

- [docs/plans/v0.11-tui-and-memory.md](../plans/v0.11-tui-and-memory.md)
- [ADR 0003](0003-memory-files-are-durable-chat-history-is-not.md)
- [ADR 0041](0041-memory-retrieval-uses-bounded-prefetch-and-explicit-search-read.md)
- [ADR 0042](0042-autonomous-learned-memory-writes-go-to-staging-before-promotion.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
