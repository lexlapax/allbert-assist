# Allbert Future Features Parking Lot

This file tracks work that is not assigned to a concrete roadmap milestone.
It is a strict parking lot, not release history and not a duplicate roadmap.

For planned work, use `docs/plans/roadmap.md` and the matching versioned plan.
When a parked item is partially promoted, keep only the unplanned remainder
here.

## Parked Future Features

### System Memory Distillation

Status: parked.

v0.39b ships the deterministic precursor: an inert `identity` system memory
namespace (declared via the non-app system-namespace declarer and surfaced as
a 5th `Memory` category under
`<ALLBERT_HOME>/memory/identity/`) plus deterministic recency-weighted
lexical Active Memory retrieval over reviewed `:kept` entries scoped to
`{thread_id, active_app, identity_namespace}`. Replayable from traces.
No embeddings; no learned ranking.

v0.46 plans operator-supervised trace-derived draft suggestions. Neither
v0.39b nor v0.46 trains, distills, or creates a learned system-memory
authority.

Still parked:

- nightly memory/personality distillation;
- small local model training from operator history;
- learned system-memory models that influence runtime behavior;
- deletion, reproducibility, privacy, and eval policy for any trained memory
  artifact.

### Autonomous Skill Creation Beyond Supervised Drafts

Status: parked.

v0.46 plans operator-supervised, inert trace-to-skill and trace-to-workflow
draft suggestions. Drafts remain disabled/untrusted until reviewed and
confirmed.

Still parked:

- autonomous skill creation from traces;
- auto-enable, auto-publish, or marketplace submission;
- broad execution permissions derived from repeated use or model confidence;
- autonomous package install, remote plugin install, or arbitrary code loading.

### Dynamic Capability Expansion Beyond v0.46 Facades

Status: parked.

v0.36-v0.38 now define the supervised dynamic capability path: sandbox/gate
evidence, dynamic action integration, and templated creation. v0.46 may add
only reviewed delegate facades for memory promotion/update drafts and
objective/workflow draft writes.

Still parked:

- settings, secrets, shell, package-install, confirmation-decision, trust, or
  live workspace/canvas write facades;
- broader generated-permission ceilings beyond the reviewed v0.46 memory and
  workflow draft paths;
- unsupervised self-recompilation, compiler-loop bootstrapping, or runtime
  mutation outside the v0.36/v0.37/v0.38 review path.

### SMS Channel Adapter

Status: parked.

Discord and Slack are planned for v0.43. WhatsApp, Signal, iMessage, and Matrix
are planned for v0.49. SMS remains parked.

Still parked:

- phone-number mapping and ownership recovery;
- short-message truncation and partial-output UX;
- cost, rate-limit, and abuse policy;
- provider delivery failure handling.

### Agent URI Execution And Broader Agent Endpoints

Status: parked.

v0.40 plans MCP client execution. Future `agent://` and `agent+https://`
endpoint execution remain parked.

Still parked:

- remote agent endpoint discovery and authentication;
- cross-scheme grant policy for agent resources;
- remote agent impersonation defenses;
- channel-native Approval Handoff for agent endpoints.

### MCP Apps Iframe Model

Status: parked.

v0.49 plans public API, ACP, MCP-server, and AG-UI/A2UI bridge exposure.
Allbert remains catalog-bound for UI surfaces.

Still parked:

- MCP Apps sandboxed iframe execution;
- third-party remote UI code trust policy;
- CSP expansion for iframe-hosted apps;
- compatibility between MCP Apps UI and Allbert's validated Surface DSL.

### MCP Client v0.40-Deferred Remainder

Status: parked. Added in the v0.40 readiness pass.

v0.40 ships the MCP client with HTTP/SSE and stdio transports, tool calls
(confirmation-gated), and resource reads (grant-gated). A few MCP client
capabilities are intentionally out of v0.40 scope.

Still parked:

- WebSocket MCP transport (v0.40 ships HTTP/SSE and stdio only);
- remembered or silent MCP tool-call approval (every v0.40 tool call confirms;
  per ADR 0038 there is no remembered tool-call grant);
- MCP prompts consumption (v0.40 consumes tools and resources only);
- MCP server mode (Allbert exposing its own MCP server) — covered by the v0.49b
  MCP server-mode surface and the "Public Protocol Interop (Non-MCP)" entry, not
  the v0.40 client.

### Broad Office, Archive, And Unknown-Binary Extraction

Status: parked.

v0.42 plans bounded HTML, markdown, plain text, and PDF extraction for browser
and web research.

Still parked:

- Office document extraction;
- archive traversal;
- unknown-binary inspection;
- deeper extractor contracts, size caps, content-type mismatch handling, and
  prompt-injection/data-exfiltration evals for those formats.

### Code-Bearing Remote Plugin Distribution

Status: parked.

v0.45 plans marketplace-lite metadata and reviewed skill/template discovery.
It does not install arbitrary remote code.

Still parked:

- remote code-bearing plugin install;
- remote dependency resolution;
- binary/plugin package distribution;
- remote theme/snippet distribution;
- signing, provenance, versioning, rollback, and sandbox policy for
  third-party code.

### Hosted Multi-User Authorization

Status: parked.

Allbert's near-term identity model remains local `user_id`. Hosted accounts,
roles, teams, auth sessions, API keys, and cross-user authorization remain
future work.

### Remote Sync Service

Status: parked.

v0.50 plans local-first profile export/import dry runs. Broad remote sync
remains parked.

Still parked:

- continuous sync service;
- conflict resolution across machines;
- cloud storage/provider policy;
- shared profile authorization.

### Native Packaged UI

Status: parked.

The browser workspace remains the operator UI through v1.0.

Still parked:

- packaged macOS/Windows/Linux app;
- native notification and tray/menu behavior;
- local authentication/identity policy for a native shell;
- packaging and auto-update strategy.

### Deeper Sandbox Tiers

Status: parked.

v0.36 implements a narrow Elixir/OTP sandbox/gate path for generated drafts.

Still parked:

- broader local container sandboxing for arbitrary workflows;
- microVM or remote sandbox execution;
- untrusted scripts/package installs under stronger isolation;
- hosted or multi-user sandbox isolation.

### Scripting Engine Interface

Status: parked.

v0.09 runs trusted inventoried skill scripts through `run_skill_script`. No
general scripting engine is planned.

Still parked:

- Lua, Python, JavaScript, or other embedded scripting runtime;
- dependency bootstrap policy;
- untrusted-script execution model.

### Broader Distributed Operation

Status: parked.

v0.49b MCP server mode is local/public-surface exposure, not a distributed
runtime.

Still parked:

- complex multi-node operation;
- cluster state replication;
- hosted scheduler/worker coordination;
- distributed confirmation ownership.

### Public Protocol Interop (Non-MCP)

Status: parked. Added in the post-v0.37 planning pass after the v0.49 split.

v0.49b ships MCP server mode as the single 1.0 protocol surface (per ADR
0044). The original v0.49 plan bundled three additional protocol surfaces
that did not survive the post-v0.37 acceptance-matrix trim.

Still parked:

- OpenAI-compatible local HTTP API;
- ACP (Agent Client Protocol) server mode;
- public AG-UI / A2UI HTTP/WS bridge promoted from the v0.26 internal
  semantic-mapping bridge;
- shared auth/rate-limit/CSP/redaction policy beyond MCP server scope.

Each surface requires its own operator-demand evidence, its own auth/CSP
review, and its own export/import/eval coverage before promotion.

### iMessage Channel Adapter

Status: parked. Moved from v0.49 to parking in the post-v0.37 planning pass.

iMessage requires a macOS-only adapter, opt-in platform constraint, and
device-pairing recovery story distinct from WhatsApp/Signal/Matrix.

Still parked:

- macOS-only platform policy;
- device-pairing UX and recovery;
- App Store / signing implications;
- backup/restore behavior for paired sessions.

### Native Plugin Variants For Calendar / Mail / GitHub (v0.41.x Follow-On)

Status: post-1.0 follow-on candidates. Promoted from v0.41 scope in the
post-v0.37 planning pass.

v0.41 ships calendar / mail / GitHub as MCP-server-configured workspace
panels driven by the v0.40 MCP client. Native plugin variants land only when
MCP coverage proves insufficient for a specific workspace surface, memory
namespace, or intent-descriptor need.

Per-integration follow-on candidates:

- `./plugins/allbert.calendar/` — native plugin if a memory namespace or
  workspace surface beyond MCP coverage is needed;
- `./plugins/allbert.mail/` — native plugin extending v0.16 email channel
  with mail-as-app surface;
- `./plugins/allbert.github/` — native plugin if richer workspace UI or
  intent descriptors beyond the official GitHub MCP server are needed.

Each follow-on is a small focused release. None block v1.0.

### Marketplace Community Submission / Review Governance

Status: parked. Added in the post-v0.37 planning pass.

v0.45 marketplace lite ships single-vendor (Allbert-author seed bundles
only). A submission/review process for community contributions requires:

- submission workflow (PR against an index repo? hosted form?);
- reviewer ownership and rotation policy;
- revocation / takedown process;
- provenance + signing requirements for community submissions;
- trust-tier for community-reviewed vs Allbert-author-reviewed bundles.

Promote post-1.0 when the project decides on governance.

### Proactive Notifications Policy

Status: parked. Added in the post-v0.37 planning pass.

Allbert is reactive through v1.0. Operators may want Allbert to message them
first when a meeting starts, a job completes, an MCP server disconnects, a
confirmation expires, or a self-improvement suggestion is ready.

Still parked:

- per-channel proactive-message authority;
- operator-opt-in policy per notification class;
- rate-limit and quiet-hours policy;
- abuse prevention for runaway notifications;
- proactive-message audit and revocation.

### Unified Cost Dashboard And Budget Enforcement

Status: parked. Added in the post-v0.37 planning pass.

Voice (v0.47) and vision (v0.48) ship per-feature cost visibility at
confirmation time. Power operators will want a unified cross-provider
dashboard.

Still parked:

- per-provider, per-model, per-app, per-channel spend rollups;
- daily/weekly/monthly budget enforcement;
- spend-limit confirmation workflows;
- cost forecast for objectives before approval;
- export of spend audit logs.

### Anonymous Telemetry Policy

Status: parked. Added in the post-v0.37 planning pass.

Allbert is local-first. Default-off anonymous telemetry is a reasonable post-
1.0 question once the project decides what data, if any, helps maintainers
prioritize work.

Still parked:

- explicit opt-in mechanism;
- what data is collected (definitively no prompts, secrets, memory content);
- aggregation and retention policy;
- self-host endpoint vs vendor endpoint;
- operator-visible audit of every telemetry payload.

### Conversation History Full-Text Search

Status: parked. Added in the post-v0.37 planning pass.

Markdown memory has full-text search through v0.21. SQLite `Thread`/`Message`
conversation history does not. Operators may want to search prior threads.

Still parked:

- SQLite FTS5 over Message bodies;
- per-user and per-app filter;
- redaction-aware indexing;
- thread context retrieval into Active Memory (related to "Cross-Thread /
  Cross-App Memory Retrieval" below).

### Cross-Thread / Cross-App Memory Retrieval

Status: parked. Added in the post-v0.37 planning pass.

v0.39b Active Memory retrieval is scoped to `{thread_id, active_app,
identity_namespace}` with neutral/core context limited to identity + general
chunks. Operators may want assistant context drawn from prior threads or
across apps.

Still parked:

- cross-thread retrieval scope and ranking policy;
- privacy/redaction policy when surfacing other-thread chunks;
- across-app namespace mixing rules (notes_files chunks in a StockSage
  thread, etc.);
- operator-visible scope controls in the workspace.

### Plugin Auto-Update Story

Status: parked. Added in the post-v0.37 planning pass.

Reviewed plugins (Allbert-author and, post-1.0, community-submitted) will
release new versions over time. v0.45 marketplace ships single-snapshot
catalogs; updating means upgrading Allbert.

Still parked:

- version pinning per plugin;
- reviewed-upgrade workflow;
- rollback after a regression;
- breaking-change deprecation policy for plugin contracts.

### Model Fallback / Degradation Policy

Status: parked. Added in the post-v0.37 planning pass after the v0.39 plan
dropped the unspecified "explicit operator opt-in" wording. Reaffirmed in
the post-v0.38 readiness review on 2026-05-27: v0.39 ships the two-branch
provider doctor (per ADR 0047) which reports availability but does **not**
implement runtime failover. Operators see doctor output and switch profiles
manually.

Operators may want graceful degradation when the primary LLM provider is
down, rate-limited, or returning unusable output.

Still parked:

- explicit operator opt-in surface for fallback;
- per-provider failure detection policy;
- fallback-chain configuration (primary → secondary → local);
- audit/trace of fallback events;
- abuse prevention (prevent silent expensive failovers).

### Workspace Canvas Snapshot / Undo / Time-Travel

Status: parked. Promoted from "post-v0.38 deferred" to an explicit
parking-lot entry in the post-v0.37 planning pass.

v0.26 canvas substrate persists tiles but has no snapshot, undo, or
time-travel mechanism. If an operator loses canvas state they want back,
there's no recovery.

Still parked:

- snapshot trigger policy (manual, per-objective, periodic);
- snapshot storage layout in `<ALLBERT_HOME>/workspace/snapshots/`;
- undo/redo UX in the workspace shell;
- time-travel scope (per-thread, per-app, global);
- retention and pruning policy.

## Review Cadence

Review this file when closing a roadmap release, adding a roadmap milestone,
or discovering repeated operator requests that are not covered by the current
roadmap.
