# Cargo Dependency Notes

This note exists to make a few intentionally heavy dependency choices explicit.
When a subsystem adds a non-trivial new subtree, we record why it is present and
what parts of that subtree we are actually relying on.

## v0.5 Curated Memory

### Tantivy retrieval subtree

ADR 0046 commits v0.5 curated memory retrieval to [`tantivy`](https://github.com/quickwit-oss/tantivy).
This is the first meaningfully large dependency subtree added after the v0.4 skill/runtime work,
so we record it here instead of letting it blend into `Cargo.lock`.

We are using `tantivy` for:

- persistent on-disk BM25 indexes under `~/.allbert/memory/index/tantivy/`
- title/body/tags/tier/date field indexing
- filterable queries over a single index
- phrase-capable query parsing
- mmap-based cold starts
- maintained tokenization/stemming instead of a home-grown retriever

The following are tantivy's direct normal dependencies in the current v0.5 M1 tree, with the
reason they are acceptable in Allbert's local curated-memory runtime.

| Crate | Why it is present / acceptable |
| --- | --- |
| `aho-corasick` | Fast substring/pattern matching used through Tantivy's regex/query internals. |
| `arc-swap` | Cheap shared-state swaps inside Tantivy readers/searchers. Useful for a long-lived daemon. |
| `base64` | Encoding support used by Tantivy internals and metadata serialization. |
| `bitpacking` | Compression/packing for postings and fast numeric storage. Core search-engine plumbing we do not want to reimplement. |
| `byteorder` | Low-level binary encoding/decoding for index segments. Standard systems dependency. |
| `census` | Memory accounting/allocation tracking used by Tantivy internals. |
| `crc32fast` | Fast checksums for segment integrity and compressed blocks. |
| `crossbeam-channel` | Internal worker/search coordination. Fits our local concurrent daemon model. |
| `downcast-rs` | Trait-object downcasting inside Tantivy's query system. Small utility dependency. |
| `fastdivide` | Numeric optimization used by compressed index data structures. |
| `fnv` | Small fast hash implementation used in hot paths. |
| `fs4` | File locking and filesystem helpers used by Tantivy index ownership. |
| `htmlescape` | Safe escaping for Tantivy snippet/highlight support. |
| `itertools` | Collection helpers inside Tantivy implementation. Common, low-risk utility crate. |
| `levenshtein_automata` | Approximate/fuzzy matching support. We may not expose fuzzy search immediately, but it is part of the upstream query engine we are adopting. |
| `log` | Structured logging hooks from Tantivy internals. Aligns with Allbert's daemon logging model. |
| `lru` | Query/searcher-side cache structures. Valuable for repeated local memory lookups. |
| `lz4_flex` | Compression for stored/indexed data. Trades dependency weight for materially cheaper disk usage and IO. |
| `measure_time` | Lightweight timing instrumentation used by Tantivy. Acceptable observational dependency. |
| `memmap2` | Memory-mapped segment reads, which is one of the main reasons we chose Tantivy. |
| `num_cpus` | Thread-pool sizing / concurrency defaults inside Tantivy. Normal systems dependency. |
| `once_cell` | Lazy static initialization support. Common runtime utility. |
| `oneshot` | Internal one-time send/receive coordination for Tantivy tasks. |
| `rayon` | Parallel indexing/search helpers. Relevant for rebuild performance on developer machines. |
| `regex` | Query parsing/token matching support. Expected part of a text-retrieval engine. |
| `rust-stemmers` | English stemming. This is directly relevant to curated-memory recall quality. |
| `rustc-hash` | Fast hash tables in hot paths. |
| `serde` | Metadata/index serialization support. Already a core dependency family in Allbert. |
| `serde_json` | JSON metadata and interchange used by Tantivy internals and ecosystem. Already core to Allbert. |
| `sketches-ddsketch` | Internal distribution/statistics summaries. Acceptable small analytics helper. |
| `smallvec` | Small-vector optimization in hot query/index paths. Common systems dependency. |
| `tantivy-bitpacker` | Tantivy-specific compression helper crate. Part of the chosen engine's core format. |
| `tantivy-columnar` | Tantivy's columnar storage support for typed stored fields. |
| `tantivy-common` | Shared core types/utilities for Tantivy. |
| `tantivy-fst` | Finite-state transducer support used by the index/query engine. |
| `tantivy-query-grammar` | Parsed query grammar. Relevant to future explicit `search_memory` syntax. |
| `tantivy-stacker` | Memory arena/stacking support in Tantivy internals. |
| `tantivy-tokenizer-api` | Tokenizer/analyzer abstraction for search text processing. |
| `tempfile` | Safe temp-file handling during index writes. Already acceptable elsewhere in Allbert too. |
| `thiserror` | Error typing used by Tantivy. Low-risk ergonomic dependency. |
| `time` | Timestamp/date support for the indexed `date` field and related metadata. Already used in Allbert. |
| `uuid` | Internal unique IDs for Tantivy data structures and temporary/index objects. |

### Supporting M1 crates added alongside Tantivy

These are not part of Tantivy's direct subtree, but ADR 0046 and the v0.5 plan
also committed them for the curated-memory substrate:

| Crate | Why we added it |
| --- | --- |
| `pulldown-cmark` | Markdown to plain-text extraction for indexing note bodies. |
| `serde_yaml` | Staged-memory frontmatter parsing. |
| `fs2` | Advisory rebuild lock at `memory/index/.rebuild.lock`. |
| `tempfile` | Atomic write flow for manifest/index metadata and staged artifacts. |
| `sha2` | Stable content hashes for manifest entries. |

### Revisit conditions

Revisit the Tantivy choice if any of the following become true:

- Allbert needs a much smaller binary footprint than the local desktop/source target allows.
- We need a WASM-only retriever target.
- The retrieval contract shrinks enough that BM25 + phrase queries + mmap persistence are no longer worth keeping.
- Tantivy maintenance or security posture materially worsens.

If we revisit it, preserve the public curated-memory contract from ADRs 0041 and 0045:
markdown remains ground truth, the index remains derived, and operator surfaces such as
`memory status`, `memory rebuild-index`, and later `search_memory` stay stable.

## v0.12.2 Tracing and replay

ADRs 0081, 0082, and 0083 commit v0.12.2 to a session-local span trace under
`~/.allbert/sessions/<id>/trace.jsonl` with optional file-based OTLP-JSON export.

### No new top-level dependencies

v0.12.2 adds no new top-level workspace crates. The implementation reuses crates
already in the tree:

| Crate | What v0.12.2 uses it for |
| --- | --- |
| `flate2` | Gzip rotation for `trace.<n>.jsonl.gz` archives. Currently declared only in `allbert-cli`; v0.12.2 adds it to `allbert-kernel` since the writer/reader live there. |
| `serde_json` | Allbert-owned `TraceRecord` JSONL persistence and OTLP-JSON exporter shape. |
| `uuid` | Generates random bytes for trace/span identifiers. Persisted and protocol identifiers are OTel-compatible lowercase hex strings: 32 chars for `trace_id`, 16 chars for `id`/`parent_id`, not hyphenated UUID display strings. |
| `chrono` | `DateTime<Utc>` span timestamps. v0.12.2 adds `chrono` to `allbert-proto` with `default-features = false` and `features = ["serde"]` because shared `Span` payloads derive serde; `allbert-kernel` keeps its existing `clock` feature for timestamp creation. |
| `toml_edit` | Path-preserving `[trace]` default-write for existing profiles. Already present from v0.12.1. |

The existing `tracing`/`tracing-subscriber`/`tracing-appender` triple in
`allbert-kernel` continues to drive **diagnostic daemon logging only**. v0.12.2
does not change that subsystem and does not graft span-replay onto it. The new
trace storage layer lives in a new module to avoid colliding with the existing
`crates/allbert-kernel/src/trace.rs` logging-init module.

### Considered and rejected: OpenTelemetry SDK crates

v0.12.2 deliberately does **not** add the OpenTelemetry SDK crates:

- `opentelemetry`
- `opentelemetry-sdk`
- `opentelemetry-otlp`
- `tracing-opentelemetry`
- `opentelemetry-proto`
- `tonic` / `prost` (transitive of `opentelemetry-otlp`)

Rationale:

- v0.12.2 ships file-only OTLP-JSON export. Network OTLP (HTTP/gRPC) is in the
  deferred list. `opentelemetry-otlp` and its `tonic`/`prost` subtree would be
  unused weight today.
- Redaction must run before persistence, display, and export. v0.12.1 already
  established a single kernel-owned emission boundary (`ActivityUpdate`).
  v0.12.2 reuses that boundary for spans. Layering on top of
  `tracing-opentelemetry` would create a second span source to reconcile and
  push redaction below an SDK we do not control.
- OTel GenAI semantic conventions are still in Development. Allbert needs a
  durable replay schema even if external attribute names evolve. Owning the
  span shape in `allbert-proto` plus a versioned `TraceRecord` envelope keeps
  internal replay stable while the exporter remaps to current OTel names at
  export time (per ADR 0083).

### Revisit conditions

Revisit the OTel SDK decision if any of the following become true:

- Network OTLP export ships (HTTP or gRPC). At that point `opentelemetry-otlp`
  becomes load-bearing and pulling in the broader SDK is justified.
- A second in-process emission source (for example, a Rust-native instrumented
  library Allbert depends on) starts producing OTel spans that we want to
  capture alongside kernel spans.
- The OTel GenAI conventions stabilize and the upstream SDK gains
  redaction-before-emission hooks that match Allbert's privacy contract.
- Allbert needs distributed tracing across multiple hosts.

If we revisit it, preserve the v0.12.2 contracts: durable JSONL stays the
replay source of truth (ADR 0081), unconditional secret redaction stays
unconditional (ADR 0082), and v2/v3/v4 protocol compatibility stays additive
(ADR 0083).
