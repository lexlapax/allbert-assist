# ADR 0053: Content-Addressable Artifact Store

## Status

Accepted for v0.50 Artifacts Central. Amended by ADR 0054, which adds
artifact↔thread/message provenance linking and the core-kernel-vs-plugin
browsing-surface split (the operator browser ships in v0.50b).

## Context

Through v0.49, durable media accumulated as ad-hoc, per-subsystem files: v0.48
voice retained captures under `<ALLBERT_HOME>/audio`, v0.49 vision retained media
under `<ALLBERT_HOME>/images`, v0.49 generated-image outputs under
`<ALLBERT_HOME>/generated_images`, generated media handles, and browser-research
downloads. Those retained roots exist only as settings-default strings, are not
deduplicated, carry no uniform metadata, and have no shared identity. As channels
(v0.52+) begin forwarding attachments and MCP server mode (v0.51) begins
exposing resources, the absence of a canonical artifact home becomes a liability.

Allbert needs **one** uniform, type-agnostic, durable store for artifacts that
are uploaded by the operator, created by Allbert, or found by Allbert through
approved tools — addressable independently of any transport-specific resource
URI.

## Decision

Build a **thin content-addressable store in-tree on BEAM primitives**, not on a
third-party package.

### Build vs. library

The Elixir/Hex landscape was evaluated (v0.50 planning research):

- **hashfs** — abandoned (last release 2017, source repo gone), uses SHA-1 with
  a git-blob header, single-level shard, and stores **no metadata**. Rejected.
- **scarab** — 2016, pre-1.0, abandoned; its namespace→hash linking is a good
  idea but it carries no metadata and no retention. Reference-only.
- **dasl** — an IPFS/IPLD CID/CAR **encoding** layer, not a local file store.
  Reference-only (adopt only if CID/CAR interchange is ever required).
- **waffle** — an upload/transform library: storage key is filename/scope, not a
  content hash; pulls `hackney` and an Ecto/ImageMagick-shaped workflow that
  fights an Allbert-Home content-addressed layout. Rejected for this purpose.
- **Capsule** — Apache-2.0, 1.0, zero declared deps, a clean `Storage`/`Locator`
  abstraction — but explicitly leaves content-addressing/hashing to the caller.
  Parked as a future seam if a pluggable backend (e.g. S3) is ever needed.

The "hard part" is in OTP stdlib: `:crypto.hash(:sha256, …)` (streaming-capable),
`Base.encode16/2`, sharded `Path.join`, and atomic `File.rename` give the entire
store in ~100–150 reviewable lines with zero supply-chain, licensing, or
maintenance risk and no heavy deps. The store is therefore owned in-tree.

### Identity and layout

- Identity: `artifact://sha256/<hex>` — the lowercase Base16 SHA-256 of the
  bytes (`^[a-f0-9]{64}$`). Immutable and dedup-keyed; distinct from the mutable
  capture-id schemes (`mic://`, `image://`, `screen://`).
- Object layout: `<ALLBERT_HOME>/artifacts/objects/<first2>/<next2>/<sha256>`, a
  real Home root registered through `Paths`/`Runtime.Paths`.
- Dedup: identical content → identical path; writes go to a same-filesystem temp
  file then `File.rename` into place (atomic), skipping if the object already
  exists. Concurrent identical writers converge without locks.
- Metadata: a markdown-first per-artifact sidecar under `artifacts/index/`
  carrying a strict allow-list (`sha256`, `mime`, `byte_size`, `origin`,
  `source_resource_uri`, `created_at`, `retention`, `redaction_status`,
  `lifecycle`, bounded `provenance`), plus an in-memory `sha256 → metadata`
  lookup index. Metadata is decoupled from the object layer; raw
  bytes/filenames-as-content never enter traces.

### Security and lifecycle

- Permissions `:artifact_read` (floor `:allowed`), `:artifact_write` (floor
  `:allowed`, gated by `artifacts.enabled` + retention policy, no external call),
  `:artifact_delete` (floor `:needs_confirmation`), with matching operation
  classes and an `:artifact_store` origin kind in `OperationClass`.
- Retention is default-off (`artifacts.retention_enabled` false), reusing the
  v0.48 `retention_enabled` mechanism; a supervised mark-and-sweep GC reconciles
  the index against on-disk objects for operator-policy removal.
- The `Runtime.Redactor` gains an `artifacts` surface; `content_sha256` is
  trace-safe identity and raw bytes are never traced/audited/assigned/printed.
- Ingestion adds the codebase's first supervised `Jido.Sensor`, advisory only:
  it ingests the durable-retention branch of capture flows through the same
  `put_artifact` path as actions but never grants authority or auto-promotes to
  memory.

### Authority

A content address, a stored metadata record, or a doctor success never grants
read/write/send permission. Security Central and Resource Access remain the
authority boundary.

## Consequences

- Positive: one canonical, deduplicated, type-agnostic artifact home; uniform
  provenance/metadata; trace-safe identity; no third-party supply-chain or
  maintenance risk; a clean substrate for v0.52+ channel attachments and v0.51
  MCP resource exposure; v0.59 export/import inventories the `artifacts/` root as
  one more Home subtree.
- Negative: the project owns correctness of atomic writes, dedup, and GC (simple
  and well-trodden — rename-into-place handles the race; identical content is
  idempotent). A first supervised `Jido.Sensor` pattern must be designed without
  an in-repo precedent.
- Neutral: no content interpretation (resize/transcode/OCR), no remote sync, and
  no IPFS/IPLD interchange in v0.50; `Capsule` is the documented escape hatch if
  a pluggable backend is later required.

## Related

- ADR 0042 (audio/image/media resource classes; gains the artifact amendment).
- ADR 0031 (settings schema fragment authority — the `artifacts.*` fragment).
- ADR 0046 (settings schema `schema_version` migration policy).
- ADR 0047 (provider doctor contract — the redacted artifact-doctor envelope).
- ADR 0054 (artifact provenance linking + browser-surface split; amends this).
- `docs/plans/v0.50-plan.md`, `docs/plans/v0.50-request-flow.md`.
