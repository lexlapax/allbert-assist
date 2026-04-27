# ADR 0109: v0.15 rescopes the services size gate for concrete RAG behavior

Date: 2026-04-27
Status: Accepted

Amends: ADR 0100
Related: ADR 0106, ADR 0107, ADR 0108, ADR 0110

## Context

ADR 0100 introduced the core/services split and kept
`crates/allbert-kernel-services/src/` below 30,000 checked-in Rust lines after
the v0.14.2 migration removed duplicated contracts and moved the large runtime
unit-test suite out of `src/`.

v0.15 is different in kind from the split release. It deliberately adds concrete
service behavior to `allbert-kernel-services`: the derived SQLite RAG store,
FTS, `sqlite-vec`, Ollama embeddings, source collectors, hybrid retrieval,
memory/session recall collection, prompt-time RAG rendering, and the read-only
`search_rag` tool. Moving those concrete behaviors to core would violate ADR
0100's contract boundary. Hiding production service code outside `src/` would
violate the size gate's purpose.

The v0.15 M4 validation run reported:

```text
future allbert-kernel-services src/              32592 LOC  limit <30000  FAIL
```

The failure is real: the old ceiling no longer matches the accepted v0.15 RAG
scope.

ADR 0110 adds collection-aware RAG and a built-in user RAG skill before v0.15
closeout. That scope still belongs in `allbert-kernel-services` because
collection schema, trusted-root ingestion, URL ingestion guards, search
filtering, prompt eligibility, and daemon maintenance are concrete service
behavior, not core DTO logic.

## Decision

Raise the services size gate from `<30000` to `<40000` checked-in Rust lines for
`crates/allbert-kernel-services/src/`.

Keep the other ADR 0100 gates unchanged:

- `crates/allbert-kernel-core/src/` remains `<20000`;
- `crates/allbert-kernel-core/src/lib.rs` remains `<4000`;
- the retired `crates/allbert-kernel` crate must remain absent;
- core must not depend on services;
- services must not depend on the retired monolith;
- production service code must stay under `src/` and count against the gate;
- large test suites may stay outside `src/` only when still compiled by
  `cargo test`.

The new limit is a review trigger, not a license to grow the services crate
indiscriminately. If services approaches 40,000 LOC, the next release must
either split concrete service modules into narrower crates with a clear contract
boundary or retire old service code.

Collection-aware M7 work must stay within this `<40000` gate. If the RAG skill
or collection ingestion pushes the services crate near the ceiling, the
implementation must split along a concrete service boundary instead of raising
the gate again inside v0.15.

## Consequences

**Positive**

- v0.15 can keep real RAG behavior in the service layer where ADR 0106 placed
  it.
- v0.15 can add collection-aware user RAG without moving source policy or
  trusted-root or URL ingestion into core.
- The size gate remains honest: production code is counted instead of hidden.
- The release validation path keeps a concrete ceiling and still fails on
  unbounded growth.

**Negative**

- The services crate has a larger short-term review surface than v0.14.2
  allowed.
- Future feature work has less headroom before another split or retirement pass
  is required.
- M7 consumes more of the v0.15 services headroom and should be reviewed as a
  release-blocking expansion, not a casual doc tweak.

**Neutral**

- This does not change the core/services dependency direction.
- ADR 0110 changes operator-visible RAG behavior, but not the reason the
  concrete behavior belongs in services.

## References

- [ADR 0100](0100-kernel-splits-into-core-and-services.md)
- [ADR 0106](0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md)
- [ADR 0107](0107-rag-vectors-use-local-ollama-embeddings-and-sqlite-vec.md)
- [ADR 0108](0108-rag-indexing-is-daemon-maintained-and-channel-visible.md)
- [ADR 0110](0110-rag-collections-separate-system-and-user-corpora.md)
- [docs/plans/v0.15-rag-recall-help.md](../plans/v0.15-rag-recall-help.md)
