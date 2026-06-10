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

v0.47 ships operator-supervised trace-derived draft suggestions. Neither
v0.39b, v0.47, nor the v0.47b/`0.47.1` handoff draft release trains,
distills, or creates a learned system-memory
authority.

Still parked:

- nightly memory/personality distillation;
- small local model training from operator history;
- learned system-memory models that influence runtime behavior;
- deletion, reproducibility, privacy, and eval policy for any trained memory
  artifact.

### Autonomous Skill Creation Beyond Supervised Drafts

Status: parked.

v0.47 ships operator-supervised, inert trace-to-skill and trace-to-workflow
draft suggestions, and v0.47b/`0.47.1` ships supervised handoff drafts for
templates, marketplace metadata, delegate-plugin requests, capability gaps,
and objectives. Drafts remain disabled/untrusted or otherwise inert until
reviewed and routed through the existing confirmed/gated path for their kind.

Still parked:

- autonomous skill creation from traces;
- auto-enable, auto-publish, or marketplace submission;
- broad execution permissions derived from repeated use or model confidence;
- autonomous package install, remote plugin install, or arbitrary code loading.

### Dynamic Capability Expansion Beyond v0.47 Facades

Status: parked.

v0.36-v0.38 now define the supervised dynamic capability path: sandbox/gate
evidence, dynamic action integration, and templated creation. v0.47 ships only
reviewed delegate facades for memory promotion/update drafts and workflow
draft writes; v0.47b/`0.47.1` ships objective and handoff draft kinds on that
same supervised path.

Still parked:

- settings, secrets, shell, package-install, confirmation-decision, trust, or
  live workspace/canvas write facades;
- broader generated-permission ceilings beyond the reviewed v0.47 memory and
  workflow draft paths and the shipped v0.47b handoff draft kinds;
- unsupervised self-recompilation, compiler-loop bootstrapping, or runtime
  mutation outside the v0.36/v0.37/v0.38 review path.

### SMS Channel Adapter

Status: parked.

Discord and Slack shipped in v0.52. **Matrix, WhatsApp (Cloud API), and Signal
(`signal-cli` daemon) are v0.53 build scope.** SMS and iMessage remain parked.

Still parked:

- phone-number mapping and ownership recovery;
- short-message truncation and partial-output UX;
- cost, rate-limit, and abuse policy;
- provider delivery failure handling.

### Viber Channel Adapter

Status: parked (validated on paper in the v0.53 pass; build deferred).

Viber's Bot API is a clean **structural twin of the v0.53 WhatsApp Cloud API
channel** and confirms the public signed-webhook ingress construct generalizes:
public HTTPS webhook with an `X-Viber-Content-Signature` raw-body HMAC keyed by
the bot **auth token** (vs WhatsApp's `X-Hub-Signature-256` keyed by a separate
app secret — same construct, Viber-specific verifier + secret slot), raw `Req` +
a Phoenix controller (the only Hex lib `viberex` is dead since 2018),
`threading: :flat` (no reply/thread primitive — linear per-`sender.id` stream),
approval primitives `:button` + `:typed_command` + `:link` + `:list`
(keyboard `reply` buttons round-trip the payload as a normal message, and
`:list` remains the mandatory ADR 0016 fallback), `trust_class:
:server_readable` (bot traffic is TLS-in-transit, server-readable — **not**
E2EE-origin), and an opaque, stable, per-bot `sender.id` with **no phone PII**
(cleaner than WhatsApp's `wa_id`).

Deferred because every Viber bot created after 2024-02-05 carries a **~€100/month
standing maintenance fee** (plus per-message for out-of-session) — poor value for
a single-operator self-host versus Telegram/Matrix/WhatsApp, and Viber's user
base is regionally concentrated. Trivial to build on the v0.53 webhook construct
if a specific operator needs Viber reach.

Still parked:

- the standing monthly bot fee + per-message commercial gate;
- subscriber persistence (no list API) and the 24h session window;
- the Admin Panel bot-account approval flow.

### Agent URI Execution And Broader Agent Endpoints

Status: parked.

v0.40 plans MCP client execution. Future `agent://` and `agent+https://`
endpoint execution remain parked.

Still parked:

- remote agent endpoint discovery and authentication;
- cross-scheme grant policy for agent resources;
- remote agent impersonation defenses;
- channel-native Approval Handoff for agent endpoints.

### Operator-Authorable And Third-Party Delegate Agents

Status: v0.46 shipped the developer-authored delegate-agent extension point;
operator no-code authoring remains parked. Added in the post-v0.45 planning
pass.

The v0.24 delegate-agent substrate (`AllbertAssist.Objectives.AgentRegistry`
+ the `:delegate_agent` step + the `delegate_agent` action) has, through
v0.45, a single consumer (StockSage native financial specialist agents,
ADR 0022). v0.46 Delegation Hardening And Research Specialist addressed the
near-term gaps:

- **second consumer (shipped in v0.46):** a plugin-contributed
  research/summarize specialist (`research.specialist`) proves the contract
  against a second domain before the v1.0 freeze (ADR 0021 amendment A21);
- **third-party plugin authoring (shipped as a developer contract in v0.46):**
  `docs/developer/delegate-agents.md` documents the registration contract,
  so reviewed plugins can register delegate agents through the existing
  boundary.

Still parked (the remainder):

- **operator no-code delegate-agent authoring** — an operator (not a
  developer) defining a new delegate agent without writing Elixir. This
  must route through the supervised dynamic-capability path
  (v0.36 sandbox/gate, v0.37 gated live integration, v0.38 templates).
  v0.47b self-improvement can propose an **inert delegate-plugin draft
  request** (a developer-shaped plugin scaffold routed through the v0.38
  plugin template and the v0.36/v0.37 gate), but operator no-code authoring
  itself — an operator standing up a live agent without code or the gate
  path — stays parked. Neither is autonomous agent creation, which stays
  parked under "Autonomous Skill Creation Beyond Supervised Drafts";
- **a shared delegate-agent behaviour abstraction** — extracting a common
  framework across consumers. Per ADR 0021's "wait for ≥ 2 consumers"
  rule, v0.46 makes this possible but does not perform the extraction; a
  future release with more consumers may;
- **remote or distributed delegate agents** — covered by "Agent URI
  Execution And Broader Agent Endpoints" above;
- **delegate-agent marketplace distribution** — covered by the
  marketplace governance and "Remote Workflow Distribution" entries.

### MCP Apps Iframe Model

Status: parked.

v0.51 ships MCP server mode, an OpenAI-compatible API, and ACP server mode.
MCP Apps iframe exposure and public AG-UI/A2UI bridge exposure remain parked
after v1.0. Allbert remains catalog-bound for UI surfaces.

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
- MCP server mode (Allbert exposing its own MCP server) — shipped by the v0.51
  Public Protocol Surfaces release, not the v0.40 client.

### MCP Tool Discovery v0.42-Deferred Remainder

Status: parked after the v0.42 implementation. Added in the post-v0.40
planning pass.

v0.42 ships `find_tools` (local + internet MCP registry search), the
confirmation-gated connect gate, and an opt-in background scan over the official
MCP Registry plus optional keyed subregistries only when explicitly configured
(PulseMCP is optional, not assumed no-auth). A few discovery capabilities are
intentionally out of v0.42 scope.

Still parked:

- capability-gap-triggered remote acquisition (an objective gap automatically
  proposing a discovery search) — v0.42 keeps discovery operator-initiated or
  scheduled; ADR 0033 objectives may consult `find_local_tools` only;
- semantic registry sources (e.g. Smithery), and registries beyond the official
  registry plus an explicitly configured optional PulseMCP source;
- any auto-connect or remembered/silent connect approval
  (`mcp.discovery.auto_connect` stays pinned `false`);
- community trust scoring, registry-moderation authority, or signing/provenance
  enforcement beyond advisory flags at consent;
- discovery of non-MCP capability sources (code-bearing plugins, `agent://`
  endpoints) — those remain in their own parked entries.

### Broad Office, Archive, And Unknown-Binary Extraction

Status: parked.

v0.43 shipped bounded HTML, markdown, plain text, and PDF extraction for browser
and web research. Broader formats remain parked outside the v0.43 release.

Still parked:

- Office document extraction;
- archive traversal;
- unknown-binary inspection;
- deeper extractor contracts, size caps, content-type mismatch handling, and
  prompt-injection/data-exfiltration evals for those formats.

### Authenticated Browser Operation And Persistent Profiles

Status: parked.

v0.43 ships ephemeral browser sessions only: cookies, local storage, and
IndexedDB are discarded on session close; form fill and download deny by
default and require explicit opt-in plus confirmation; headless-only; one
active page per session; macOS + Linux only.

Still parked:

- persistent browser profiles under `<ALLBERT_HOME>/cache/browser/`;
- credential storage, autofill profile data, and saved password reuse;
- login flow recording and playback;
- captive-portal and SSO redirect chains that need same-host re-entry;
- authenticated tool calls that depend on a logged-in session;
- multi-tab, multi-window, and popup orchestration;
- headed mode and operator-visible browser windows;
- Windows / WSL2 driver support;
- JavaScript evaluation actions (`evaluate_js`, `add_init_script`,
  `expose_function`);
- WebSocket, service worker registration, push notifications, background
  sync, geolocation, microphone, camera, or clipboard access from the
  browser plugin;
- recursive crawling, sitemap traversal, or automated link following;
- broad upload (multipart file POST) beyond a future explicitly opted-in and
  confirmed `:browser_form_fill` flow.

Each widens the v0.43 trust posture and needs its own policy, storage,
redaction, and eval story before re-entry.

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

v0.57 plans local-first profile export/import dry runs. Broad remote sync
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

v0.51 public protocol exposure is local public-surface exposure, not a
distributed runtime.

Still parked:

- complex multi-node operation;
- cluster state replication;
- hosted scheduler/worker coordination;
- distributed confirmation ownership.

### Public UI Protocol Interop Remainder

Status: parked. Added in the post-v0.37 planning pass after the v0.53 split.

v0.51 ships MCP server mode, an OpenAI-compatible API, and ACP server mode
(per ADR 0044). The original v0.53 plan also bundled public UI protocol
exposure that remains too broad for the 1.0 arc.

Still parked:

- public AG-UI / A2UI HTTP/WS bridge promoted from the v0.26 internal
  semantic-mapping bridge;
- MCP Apps iframe UI;
- third-party remote UI code trust policy;
- CSP expansion and component reconciliation for public UI protocols;
- additional public protocol surfaces beyond the v0.51 MCP/OpenAI/ACP set.

Each remainder requires its own operator-demand evidence, auth/CSP review,
remote-UI trust story, and export/import/eval coverage before promotion.

### iMessage Channel Adapter

Status: parked. Moved from v0.53 to parking in the post-v0.37 planning pass.

iMessage requires a macOS-only adapter, opt-in platform constraint, and
device-pairing recovery story distinct from WhatsApp/Signal/Matrix.

Still parked:

- macOS-only platform policy;
- device-pairing UX and recovery;
- App Store / signing implications;
- backup/restore behavior for paired sessions.

### Native Plugin Variants For Calendar / Mail / GitHub (Post-1.0 Follow-On)

Status: post-1.0 follow-on candidates after v0.42 shipped MCP-configured
panels. Promoted from v0.42 scope in the post-v0.37 planning pass.

v0.42 ships calendar / mail / GitHub as MCP-server-configured workspace
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

### Workflow YAML Loops And Parallel Fan-Out

Status: parked. Added in the post-v0.43 planning pass.

v0.44 ships a v1 workflow YAML schema with sequential step ordering and
per-step `if:` branching only. Loop kinds (`for_each`, `for`, `while`)
and parallel/fan-out kinds (`parallel:`, `Fork`) are deliberately
excluded. Cycle and safety footguns dominate v1 schemas — Argo
Workflows, LangGraph, and Serverless Workflow `For` all report these as
the most-cited operability sinks. Reserved as `for_each` and
`parallel_steps` in ADR 0041 §"Reserved Vocabulary" so future versions
can promote without renaming. Revisit when telemetry shows real demand
and when v0.47 self-improvement traces inform what shape loops should
actually take.

### Sub-Workflow Includes And Imports

Status: parked. Added in the post-v0.43 planning pass.

v0.44 workflow YAML cannot reference another workflow as a step. The
`include:` / `import:` composition primitive expands the schema surface
by 3-4x (composition semantics, cycle detection across workflows,
version pinning for included workflows). Reserved as
`sub_workflow_include` in ADR 0041. Defer until a real consumer
appears - possibly after v0.47 self-improvement trace-to-workflow drafts
start producing reusable sub-pieces.

### Auto-Triggered Workflows (`on:` Clauses)

Status: parked. Added in the post-v0.43 planning pass.

v0.44 workflows are **operator-referenced** by design. The document
never carries `on: schedule` or `on: event` trigger clauses; scheduling
is the v0.13 jobs subsystem's job (a scheduled job MAY reference a
Plan-Build action with a workflow id as a target, but the YAML itself
stays inert). Adding `on:` clauses would turn workflow YAML from an
operator-readable inert artifact into an ambient trigger surface
without an explicit confirmation transition. Reserved as `on_schedule`
and `on_event` in ADR 0041. Promote only with a fresh authority-
boundary analysis.

### Remote Workflow Distribution / Marketplace Workflows

Status: parked. Added in the post-v0.43 planning pass.

v0.45 marketplace-lite ships catalog metadata for skills and templates
only. Workflow YAML files distributed through the marketplace would
require an additional trust tier (workflows execute through registered
actions, so a malicious workflow can still drive any allowed-floor
action without confirmation). Parked under the same governance
umbrella as "Marketplace Community Submission / Review Governance".
v0.45 marketplace metadata MAY reference workflow ids descriptively;
the catalog never installs workflow files into the live
`<ALLBERT_HOME>/workflows/` directory.

### Multi-User Collaborative Plan Editing

Status: parked. Added in the post-v0.43 planning pass.

v0.44 Plan/Build is single-user: one operator authors and approves a
plan; expand-to-fullscreen edits happen in one LiveView session at a
time. Concurrent editing of a shared plan preview (multiple operators
seeing each other's edits live) requires v0.23's reserved Cursor
concept (multi-user collaborative cursor) plus a conflict-resolution
story. Defer until hosted multi-user authorization (also parked) is on
the table.

### Proactive Notifications Policy

Status: parked. Added in the post-v0.37 planning pass.

Allbert is reactive through v1.0, with one narrow carve-out: v0.42 adds an
opt-in, paused-by-default background MCP-discovery scan (per ADR 0048) that runs
as an operator-scheduled job and writes candidates to a *passive* Discovery
Suggestions surface. That is unattended read-only scanning into a queue the
operator pulls from — Allbert still never messages the operator unprompted and
never connects without confirmation. Proactive *messaging* (Allbert pinging the
operator first when a meeting starts, a job completes, an MCP server disconnects,
a confirmation expires, or a discovery/self-improvement suggestion is ready)
remains parked.

Still parked:

- per-channel proactive-message authority (including push about discovery
  suggestions);
- operator-opt-in policy per notification class;
- rate-limit and quiet-hours policy;
- abuse prevention for runaway notifications;
- proactive-message audit and revocation.

### Unified Cost Dashboard And Budget Enforcement

Status: parked. Added in the post-v0.37 planning pass.

v0.48 ships display-only provider and usage metadata for STT/TTS action
results and traces when providers expose it. v0.49 adds the same style of
display-only metadata for image generation. Power operators will still want a
unified cross-provider dashboard, but budget enforcement remains parked here.

Still parked:

- per-provider, per-model, per-app, per-channel spend rollups;
- daily/weekly/monthly budget enforcement;
- spend-limit confirmation workflows;
- cost forecast for objectives before approval;
- export of spend audit logs.

### Post-v0.48 Media Follow-Ons

Status: parked. Added during the v0.48 third-pass readiness sweep.

v0.48 profile metadata can describe realtime audio sessions, generic
audio/video input support, local endpoint transports, and bundled-local runtime
availability, but the release scope remains bounded STT/TTS. v0.49 promotes
only the bounded image/screenshot-to-text and text-to-image bridge; it does not
promote generic audio/video understanding or a catch-all multimodal router. The
following items need their own plans, permission story, resource classes,
doctor fields, and release evidence before implementation:

- realtime speech-to-speech sessions;
- always-on or wake-word listening;
- generic audio understanding that is not transcription;
- video ingestion, sampled-frame analysis, or video generation;
- required bundled-local engine packaging for every operator;
- Discord voice after v0.52 Discord text-channel support.

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
