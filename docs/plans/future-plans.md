# Future plans

Status: Planning index

This file holds useful threads that are intentionally parked outside the active
release plan. It is not a commitment that every item below ships, or that the
release labels are final. The goal is to keep the active roadmap focused while
preserving the decisions, links, and open questions that should be picked back
up later.

Current planning anchors:

- [Roadmap](roadmap.md)
- [Vision](../vision.md)
- [Origin note](../notes/origin-2026-04-17.md)
- [ADR 0106: RAG index is a derived SQLite lexical/vector store](../adr/0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md)
- [ADR 0101: Growth-loop ingestion is daemon-owned, single-endpoint, staging-only](../adr/0101-growth-loop-ingestion-is-daemon-owned-staging-only.md)

## Growth-loop ingestion and activity capture

Status: Parked stub, extracted from the v0.15 plan on 2026-04-27.

The origin note asks for Allbert to grow with the user by observing activity
such as search queries and other day-to-day signals. That remains important,
but it should not share the first RAG release. v0.15 should make current docs,
commands, settings, memory, facts, and sessions retrievable before any new
ambient capture source expands the corpus.

Likely shape:

- one daemon-owned `IngestRecord` message rather than per-source protocol calls;
- opt-in source enablement, visible through settings;
- staging-only writes with `kind: ingestion`;
- per-record and per-day caps;
- redaction at ingest time and again at corpus-build time;
- no automatic durable memory promotion;
- promoted records join normal RAG only through the durable-memory path.

References:

- [ADR 0101](../adr/0101-growth-loop-ingestion-is-daemon-owned-staging-only.md)
- [ADR 0053: Background web learning requires explicit user intent](../adr/0053-background-web-learning-requires-explicit-user-intent.md)
- [ADR 0106](../adr/0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md)

Open questions:

- Is the first active ingestion release a full minor release or a smaller
  follow-up after v0.15?
- Does ingestion introduce protocol v7, or does another feature consume that
  version first?
- Should staged ingestion live under the existing memory staging directory with
  a new frontmatter kind, or under an ingestion-specific staging directory that
  memory-curator reads?

## CLI piped ingest feed

Status: Parked stub.

A low-risk first adapter could let an operator pipe notes, logs, shell history,
or clipboard-manager output into Allbert:

```bash
allbert-cli ingest stdin --source <name> [--kind <kind>]
```

The command should normalize records into the same daemon-owned ingestion
shape, obey the same caps, and create staged review entries only.

Dependencies:

- growth-loop ingestion endpoint;
- memory staging/review filters for ingestion records;
- operator docs that explain source naming, redaction, and purge behavior.

## Browser extension capture

Status: Parked stub.

A browser extension remains the exact page-visit and search-query capture path.
It should live in a sibling repo unless a future design pass finds a strong
reason to put browser-extension tooling in the Rust source tree.

Likely shape:

- extension posts to a loopback daemon listener;
- no source is enabled by default;
- exact page visits and search queries are captured only after operator opt-in;
- records land in ingestion staging, never durable memory.

References:

- [ADR 0101](../adr/0101-growth-loop-ingestion-is-daemon-owned-staging-only.md)
- [Roadmap deferred ambitions](roadmap.md#deferred-ambitions)

Open questions:

- Which browser family ships first?
- Does the sibling repo version lock to Allbert protocol versions or negotiate
  capabilities dynamically?
- What is the uninstall/disable story operators can verify from Allbert itself?

## Browser proxy and PAC mode

Status: Parked stub.

A local proxy plus PAC file could let an operator point a browser profile at
Allbert when an extension is unavailable or undesirable. This is weaker than an
extension for HTTPS detail and must be honest about that limitation.

Boundary for a first release:

- loopback-only listener;
- defaults off;
- no root CA installation;
- no TLS interception;
- no body inspection;
- HTTPS `CONNECT` produces host, port, timestamp, and source profile metadata
  only;
- plaintext HTTP may produce redacted full-URL records;
- `CONNECT` targets are restricted to web-safe ports by default.

References:

- [ADR 0101](../adr/0101-growth-loop-ingestion-is-daemon-owned-staging-only.md)
- [MDN: Proxy Auto-Configuration file](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file)
- [RFC 9110 section 9.3.6: CONNECT](https://datatracker.ietf.org/doc/html/rfc9110#section-9.3.6)

Open questions:

- Is proxy mode release-blocking for the first ingestion release, or
  experimental?
- Does the daemon expose one localhost HTTP listener for both extension and
  proxy ingestion, or separate listeners with shared normalization?
- How should settings and status surfaces make proxy behavior obvious while it
  is running?

## Ingestion review and corpus eligibility

Status: Parked stub.

Ingestion only becomes useful after review. The review surface should reuse the
existing staged-memory and memory-curator posture rather than invent a second
approval system.

Likely shape:

- memory-curator gains an ingestion filter;
- a disabled-by-default `ingestion-review` job compiles daily staged-ingestion
  digests;
- promoted ingestion records become eligible for RAG and adapter corpus
  inclusion under existing tier rules;
- staged ingestion records remain searchable only through explicit review
  surfaces.

References:

- [Memory direction in vision](../vision.md#memory-direction)
- [Adaptive memory operator guide](../operator/adaptive-memory.md)
- [ADR 0047: Staged memory entries have a fixed schema and rate/size/TTL limits](../adr/0047-staged-memory-entries-have-a-fixed-schema-and-limits.md)

## Expanded ingest sources

Status: Deferred.

These sources stay outside the first ingestion pass:

- Slack, Discord, iMessage, email, SMS, and chat-message body ingestion;
- screenshot or clipboard-image OCR ingestion;
- active-window and keystroke ingestion;
- cross-device ingestion sync.

Any source that touches private communications, screen contents, or keystrokes
needs its own design pass, operator education, and rollback/purge story.

## Ingestion-driven learning refresh

Status: Deferred.

Promoted ingestion records may eventually trigger or influence adapter training
and personality-digest refresh cadence. That should remain separate from the
first ingestion release. The first requirement is that promoted records join
existing durable-memory and adapter-corpus eligibility paths without special
privilege.

References:

- [v0.13 personalization plan](v0.13-personalization.md)
- [Personality digest operator guide](../operator/personality-digest.md)
- [ADR 0084: Personality adapter job is a learning job with an owned trainer trait](../adr/0084-personality-adapter-job-is-a-learning-job-with-an-owned-trainer-trait.md)

## Provider-native tool calling

Status: Future seam.

Provider-native tool calling is adjacent to the router/RAG work but should not
be bundled into v0.15 unless the RAG implementation explicitly needs it. The
current source tree already has the schema-bound router repair from v0.14.3 and
provider-owned parsing improvements from v0.14.1; native provider tools can
land as a focused follow-up.

References:

- [v0.14.1 vision alignment plan](v0.14.1-vision-alignment.md)
- [ADR 0096: Tool-call parser accepts schema variants](../adr/0096-tool-call-parser-accepts-schema-variants.md)

Open questions:

- Which providers get native tool surfaces first?
- How do provider-native tools preserve the existing policy, cost, and hook
  envelope?
- Does native tool calling simplify router output, or does it remain only a
  provider invocation optimization?
