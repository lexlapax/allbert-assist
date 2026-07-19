# Allbert Future Features — Post-1.0 Inventory

This file is the consolidated post-1.0 inventory of work that is not assigned
to a concrete roadmap milestone. It remains a strict parking lot, not release
history and not a duplicate roadmap. Post-1.0 it is additionally the
prioritization inventory: every entry carries a proposed MoSCoW class and an
effort tag so the operator can run a category-by-category prioritization pass.

For planned work, use `docs/plans/roadmap.md` and the matching versioned plan.
Backlog lifecycle rule (mirrored in AGENTS.md and the roadmap Working Rules):
when an item gains an implementation plan, its entry here is marked
`Status: planned — docs/plans/vX.Y.Z-plan.md M<n>` and the roadmap ladder links
the plan triad. After that plan is implemented and tagged, the planned part is
removed from this file entirely — only an unplanned remainder stays, reparked
with its provenance — and the roadmap is updated accordingly. This file never
holds shipped history.

This revision folds in the v1.0 closeout sweep of every archived plan,
request-flow, handoff, ADR, roadmap, and operator/developer doc: items that
were deferred in an archived plan and never shipped or parked appear as new
entries with their provenance; pre-existing parked sections are preserved
verbatim and grouped by category.


## Release Ladder (operator-confirmed 2026-07-14)

Supersedes any per-entry `Slice: 1.1` tag where they conflict — flagships are
sequenced one per minor, foundational-first:

- **1.0.1 / 1.0.x** — **1.0.1 SHIPPED** (tagged 2026-07-15, source/docs point tag:
  R15, btn drift, offline SW test, DIT-5 transcript, DIT-4 remediation M4.1–M4.5,
  dependency refresh incl. vendored `:memento` removal). Next 1.0.x increments:
  test speed & isolation, v0.58 tails, docs items; the next **binary** release
  carries the 1.0.1 fixes into the packaged artifact line. Its final measured
  isolation remainder is written back here before the v1.0.2 tag; shipped
  entries are removed only after published-artifact validation and closeout.
- **1.1 — Asynchronous Background Agent Fan-Out With In-Channel Steering**
  (operator intake 2026-07-18, inserted as the new first minor: the async
  runtime/interaction model is foundational — 1.3's memory consolidation jobs
  and 1.4's profiling analysis are themselves background agents and build on
  this substrate rather than retrofit it).
- **1.2 — Zero-Click First Run** + its direct enablers (model chooser/catalog,
  model fallback/degradation for the detect states, consent ADR, folded TUI scope).
- **1.3 — Long-Term User Memory** (research phase first; folded retrieval/FTS/
  working-memory scope). Free-form provider URLs and bind hardening stay on this
  horizon as tagged.
- **1.4 — Adaptive Usage Profiling** (stages a/b/c; per-role model profiles and
  proactive notifications ride here; consumes 1.3's memory substrate).
- **1.5 / 1.6 — the remaining confirmed enablers**, sliced by need: the
  migration-runner cluster (runner + telegram/email settings migration + legacy
  intent.*model_profile removal + automated rollback — pulled EARLIER if any 1.1-1.4
  release needs a non-additive migration), email OAuth, MCP spec parity,
  param-contract completion, PermissionGate deletion, mid-action interruption +
  child-process cancellation, app-registry boundary check. System Memory
  Distillation remains the post-profiling co-flagship candidate. **2.0 horizon**:
  Self-Hosting Development (Allbert develops Allbert, pi-mode target), with OAuth
  hosted-LLM providers landing earlier on the 1.5/1.6 enabler train.
## Classification

Classes are **proposed** pending the operator's category-by-category
prioritization pass — nothing below is committed until that pass happens.

- **MoSCoW class**: `Must` (do next; items marked "(foundational)" unblock
  other work and should be sequenced first), `Should` (high-value, not
  blocking), `Could` (worth doing if a release has room or a consumer
  appears), `Won't-now` (indefinitely parked strategic items; revisit only on
  strong operator demand or a posture change).
- **Effort**: `S` (days), `M` (a milestone-sized chunk), `L` (a release or
  more).
- Entries needing operator triage before classification is trusted carry a
  `Verify:` marker on the class line and appear in the Triage Notes table at
  the end.

Provenance shorthand used in `Deferred at:` lines: `vX.YY-plan:N` and
`vX.YY-rf:N` point into `docs/plans/archives/vX.YY-plan.md` /
`vX.YY-request-flow.md`; `v1.0-handoff:N` into
`docs/plans/archives/v1.0-handoff.md`; `roadmap:N` into
`docs/plans/roadmap.md`; `adr/NNNN:N` into the numbered ADR under
`docs/adr/`; `operator/...` and `developer/...` into `docs/operator/` and
`docs/developer/`. Line numbers are as of the 2026-07-14 consolidation sweep.

## Platform & Runtime Debt

### Settings Runtime Migration Runner

Class: Must (foundational) (confirmed 2026-07-14) · Effort: M · Slice: 1.1 — unconditional; first consumer is the Telegram/Email plugin-owned-settings migration

Status: parked (deferred until the first non-additive settings migration).

A `mix allbert.settings.migrate` runner plus a Migration DSL for settings
schema changes that are not purely additive. Deferred in v0.59, re-deferred in
the v1.0 plan; ADR 0046 records the deferral condition. Every future
settings-shape change lands on this item first — it gates plugin-owned
settings migration, legacy-key removal, and any rename.

Deferred at: `roadmap:2850`, `adr/0046:67`, `v0.59-plan:135`, `v1.0-plan:137`.

### PermissionGate Deletion / Parity Pass

Class: Must (foundational) (confirmed 2026-07-14) · Effort: M · Slice: 1.1 (not frozen — verified against public-contract-freeze.md)

Status: parked.

PermissionGate is still a shim after the v0.31 permission rework. A deletion
or parity pass removes the shim so future permission work has one authority
path.

Deferred at: `v0.31-rf:112`.

### Full Cross-Action Param-Contract Enforcement

Class: Must (foundational) (confirmed 2026-07-14) · Effort: M · Slice: 1.1 · Verify first: diff the v0.59-shipped scope against the full v0.54 cross-action scope

Status: verify.

v0.54 planned full cross-action param-contract enforcement; a bounded scope
shipped later (v0.59-era). The remainder — enforcement across every action
boundary — completes the contract story that generated actions, workflows,
and public protocol surfaces all lean on.

Deferred at: `v0.54-plan:1291`.

### Core-Action `app_id` Ownership (Option 2)

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: hold until app-scoped routing pain appears

Status: parked.

The v0.54 plan chose a bounded option for core-action `app_id` handling and
recorded "Option 2" (proper ownership semantics for core actions) as the
follow-on.

Deferred at: `v0.54-plan:133`.

### App-Registry Membership Check At Action Boundary

Class: Should (confirmed 2026-07-14) · Effort: S · Slice: 1.1 (operator-confirmed 2026-07-18 over the roadmap's 1.5/1.6 listing) · Verify first: whether later releases already added a boundary check

Status: planned — `docs/plans/v1.1-plan.md` M0 (verify) + M7 (implementation).

v0.15 deferred validating app-registry membership at the action boundary
(actions trusting the caller-supplied app identity).

Deferred at: `v0.15-plan:670`.

### Mid-Action Interruption / In-Flight Kill

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: 1.1 (one milestone with Child-Process Cancellation)

Status: planned — `docs/plans/v1.1-plan.md` M4 / ADR 0085.

v0.24 deferred interrupting or killing an in-flight action mid-execution.
Operators can only wait out a long-running action today.

Deferred at: `v0.24-rf:466`.

### Child-Process Cancellation Semantics

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: 1.1 (merged with Mid-Action Interruption)

Status: planned — `docs/plans/v1.1-plan.md` M4 / ADR 0085.

v0.57 deferred defining cancellation semantics for spawned child processes
(what happens to external work when the owning request dies). Related to
"Mid-Action Interruption / In-Flight Kill" above.

Deferred at: `v0.57-plan:845`.

### Force/Retry Job Mode

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold — revisit if the adaptive-loop jobs create the need

Status: parked.

v0.13 deferred a force/retry mode for scheduled jobs (re-run a failed or
skipped job on demand).

Deferred at: `v0.13-rf:147`.

### `objectives.rehydrate_window_minutes` Setting

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold until operator need

Status: parked.

v0.24 deferred exposing the objectives rehydrate window as an operator
setting.

Deferred at: `v0.24-rf:782`.

### Intent Pipeline Refinements

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: 1.0.x opportunistic (piggyback on any intent-touching release)

Status: parked.

Two v0.54 deferrals: an `intent_candidates` trace-block (surfacing the
candidate set in traces) and single-token tightening for the ranker.

Deferred at: `v0.54-plan:512` (intent_candidates trace-block),
`v0.54-plan:439` (ranker single-token tightening).

### `:operator` Exposure Expansion

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold — needs its own ADR per v0.55b

Status: parked.

v0.55b deferred expanding what the `:operator` exposure level covers beyond
its initial scope.

Deferred at: `v0.55b-plan:100`.

## Packaging & Distribution

### Apple Notarization / Hardened-Runtime Staple

Class: Could (confirmed 2026-07-14; demoted from Must — paid-platform distribution polish is not a current priority) · Effort: M · Slice: hold

Status: parked (named as a v0.64 item; never shipped).

Notarize and staple the packaged macOS binary with the hardened runtime.
v0.62 shipped cosign signing; Gatekeeper-clean install without a quarantine
override still needs notarization. Core trust story for non-developer
installs.

Deferred at: `v0.62-plan:383`.

### Automated Migration Rollback

Class: Must (confirmed 2026-07-14) · Effort: M · Slice: 1.1, one milestone with the Settings Runtime Migration Runner

Status: parked (deferred from v0.62 to v0.64; never shipped).

Automated rollback of data/settings migrations when a packaged upgrade fails
partway. Today recovery is the manual DB-backup path.

Deferred at: `v0.62-plan:384`.

### DIT-1 Windows/WSL2 Install Walkthrough

Class: Could (confirmed 2026-07-14; Windows is not a current priority) · Effort: S · Slice: hold

Status: parked (scoped out of the v1.0 handoff matrix, not done).

The v1.0 handoff's DIT-1 item — a validated Windows/WSL2 install walkthrough —
was scoped out rather than completed. Pairs with the Tier-2 posture below.

Deferred at: `v1.0-handoff:87`.

### Packaging-Trust Re-Parked Exceptions (ADR 0076)

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: verify first — may dissolve to nothing

Status: verify.

v0.64 re-parked a set of packaging-trust exceptions under ADR 0076. The
remaining exception list needs re-triage now that v0.64–v1.0 shipped installer
cosign verification and the release gates.

Deferred at: `v0.64-plan:234`.

### Native Windows Packaging

Class: Could (confirmed 2026-07-14) · Effort: L · Slice: hold — WSL2 remains the Windows path

Status: verify.

Windows support is Tier-2 WSL2-only. Native Windows packaging (a Windows
binary, not WSL2) is recorded in the v0.62 plan but was never brought into
this parking lot until now.

Deferred at: `v0.62-plan:2221`.

### Bundled Executable Packaging For Capability Helpers

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: verify.

The provider-capabilities developer doc mentions bundling helper executables
with the package; unclear whether this is still needed post-v0.62.

Deferred at: `developer/provider-capabilities:210`.

### Native Packaged UI

Class: Could (confirmed 2026-07-14) · Effort: L · Slice: hold — web-first remains the posture

Status: parked.

The browser workspace remains the operator UI through v1.0. Note: v0.62 ships a
packaged `allbert` **binary** (a release-built CLI + `serve` daemon with a
Homebrew/curl install path, ADR 0076) — that is distribution of the existing
surfaces, not a native GUI shell. The native GUI app below stays parked.

Still parked:

- packaged macOS/Windows/Linux **GUI** app;
- native notification and tray/menu behavior;
- local authentication/identity policy for a native shell;
- packaging and auto-update strategy.

## Channels & Messaging

### SMS Channel Adapter

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked.

Discord and Slack shipped in v0.52. **Matrix shipped and validated in v0.53.**
WhatsApp (Cloud API) and Signal (`signal-cli` daemon) are implemented in v0.53
but not released for live use; their lower-friction live onboarding work is
parked below. SMS and iMessage remain parked.

Still parked:

- phone-number mapping and ownership recovery;
- short-message truncation and partial-output UX;
- cost, rate-limit, and abuse policy;
- provider delivery failure handling.

### WhatsApp Live Channel Release

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked after v0.53 M11 (reconfirmed open in the v1.0 sweep:
implementation shipped, live validation still provider-blocked).

v0.53 implemented the WhatsApp Cloud API adapter, signed-webhook ingress, setup
checks, doctor, renderer, deterministic tests, and local `post-webhook` auth
validation. Live Cloud API validation did not become release authority because
Meta onboarding returned object/permission and account-registration failures in
both the developer UI and Graph API.

Future work must decide whether to:

- harden the Cloud API production/test onboarding flow enough for a
  single-operator release bar;
- evaluate a WhatsApp Web/Baileys linked-device provider as a separate
  provider/trust model with its own ADR, custody story, and maintenance risk;
- define operator-friction acceptance criteria before marking WhatsApp live use
  released.

Until then, v0.53 records WhatsApp as implemented-not-released through ADR 0066.

### Signal Advanced-Bridge Release

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked after v0.53 M11 (reconfirmed open in the v1.0 sweep:
implementation shipped, live validation still requires operator-managed
onboarding).

v0.53 implemented the Signal `signal-cli` bridge, local custody checks, setup
checks, doctor, renderer, trust-class stamping, deterministic tests, and
advanced live runbook. Live validation is not v0.53 release authority because it
requires operator-managed daemon/link-device onboarding, ACI discovery, and
local control endpoint setup.

Future work must decide whether to:

- provide a lower-friction managed bridge or setup assistant;
- define a clearer privacy/security model for local linked-device custody;
- prove the setup can be run by an operator without installing and managing
  `signal-cli` by hand.

Until then, v0.53 records Signal as implemented-not-released through ADR 0066.

### Viber Channel Adapter

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

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

### iMessage Channel Adapter

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked. Moved from v0.53 to parking in the post-v0.37 planning pass.

iMessage requires a macOS-only adapter, opt-in platform constraint, and
device-pairing recovery story distinct from WhatsApp/Signal/Matrix.

Still parked:

- macOS-only platform policy;
- device-pairing UX and recovery;
- App Store / signing implications;
- backup/restore behavior for paired sessions.

### Proactive Notifications Policy

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: 1.1 — scoped as the suggestion-delivery stage of Adaptive Usage Profiling

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

### Email OAuth (XOAUTH2; Gmail / Microsoft OAuth-Only Mailboxes)

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: 1.1

Status: parked.

The email channel authenticates with passwords/app-passwords only. XOAUTH2
support is the named gap in the operator guide, and v0.53 separately deferred
Gmail/Microsoft OAuth-only mailboxes. Increasingly a Must-shaped item as
providers retire app passwords.

Deferred at: `operator/email-channel:14` (XOAUTH2), `v0.53-plan:516`
(Gmail/Microsoft OAuth-only mailboxes).

### IMAP IDLE Push

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked.

v0.16 email ingest polls; IMAP IDLE push delivery was deferred.

Deferred at: `v0.16-rf:465`.

### SMTP Provider API Delivery (Mailgun / SendGrid)

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold

Status: parked.

v0.16 deferred provider-API outbound delivery (Mailgun/SendGrid) in favor of
plain SMTP.

Deferred at: `v0.16-rf:554`.

### Separate Channel Registry

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked.

v0.17 deferred extracting a dedicated channel registry (channels are wired
through existing registries today).

Deferred at: `v0.17-plan:42`.

### Discord Adapter Deferred Remainder

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked.

Transport and fidelity variants deferred by the v0.52 Discord adapter:
Interactions HTTP transport (webhook-style instead of the gateway), sharding
for large-bot scale, select menus + modals as richer approval primitives,
OAuth multi-app install flow, and full 429/resume/heartbeat gateway fidelity.

Deferred at: `v0.52-plan:1063` (Interactions HTTP transport),
`v0.52-plan:1064` (sharding), `v0.52-plan:214` (select menus + modals),
`v0.52-plan:914` (OAuth multi-app install), `v0.52-plan:2066`
(429/resume/heartbeat fidelity).

### Slack Adapter Deferred Remainder

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked.

Transport and scope variants deferred by the v0.52 Slack adapter: Events API
HTTP transport (instead of Socket Mode), multi-workspace OAuth distribution,
and an outbound-ref for callback replies.

Deferred at: `v0.52-plan:1065` (Events API HTTP transport), `v0.52-plan:147`
(multi-workspace OAuth), `v0.52-plan:2067` (callback-reply outbound-ref).

### Telegram/Email Plugin-Owned-Settings Migration

Class: Should (confirmed 2026-07-14) · Effort: S · Slice: 1.1, one milestone with the Settings Runtime Migration Runner (its first real migration — makes the runner unconditional in 1.1)

Status: parked (blocked on the Settings Runtime Migration Runner above).

v0.52 deferred migrating telegram/email settings to plugin-owned settings
namespaces; the first non-additive migration needs the runner first.

Deferred at: `v0.52-plan:2312`.

### Matrix E2EE Encrypted Rooms

Class: Could (confirmed 2026-07-14) · Effort: L · Slice: hold

Status: parked.

v0.53 Matrix shipped unencrypted-room support; E2EE rooms (olm/megolm device
keys, verification, key backup) were deferred.

Deferred at: `v0.53-plan:62`.

## Workspace & Web UI

### Zero-Click First Run (Chat-Ready Default)

Class: Must (confirmed 2026-07-14) · Effort: L · Slice: 1.1 FLAGSHIP — consent ADR + folded TUI first-run scope

Status: parked (operator-directed, post-1.0 intake 2026-07-14).

Invert the first-run model: instead of requiring the non-developer to press
"Start QuickStart" and walk the wizard before chat works, the first run
**auto-detects a running local LLM**, auto-selects a local-model profile with
the generic answer engine as the default, and is **chat-ready immediately** —
no getting-started button on the critical path. Onboarding becomes a fully
optional, always-available customization surface: the operator can open it
anytime and jump **directly to any individual step** (track, model path,
persona, connections) to customize — building on the v1.0 `wizard_rewind`
step navigation and the first-chat go-signal, but generalized to arbitrary
step entry at any time, including after completion. All first-run UX/UI is
re-geared around this: drastic simplification of the first-run experience.

Design tension to resolve at promotion (needs an ADR): ADR 0078 / v0.63
treat enabling model-backed direct answers as an explicit consent step
(`intent.direct_answer_model_enabled` defaults false; QuickStart flips it).
Auto-enabling on detection is defensible for **local-only** inference (no
egress; the trust spine's Local-first and Hosted-provider-egress lines are
untouched — BYOK/hosted stays opt-in), but the consent semantics, the
detect-state matrix (`local_ready` vs `model_missing` vs `below_floor` — what
does "chat-ready" mean with no model present?), and the DIT-2 acceptance
criteria (which currently assert QuickStart enables direct answers before the
first question) must all be redefined deliberately, not incidentally.

Related entries: Model Chooser / Catalog (Packaging & Distribution); the
curated-model settings defaults (`first_model.curated_model`, shipped v1.0
M7.5); Rich TUI Onboarding Slash-Command (triage table — the TUI first-run
should follow the same inversion).

Folded in (operator decision 2026-07-14): the TUI first-run follows the same
inversion inside this feature — the post-v0.64 "Full TUI First-Run Repair
Panels" promise (`v0.64-plan:176`) and the v0.63 "Rich TUI Onboarding
Slash-Command Wizard" deferral (`v0.63-plan:1264`; verify what the v0.64 TUI
first-run already covers) are scope items of the zero-click redesign, not
standalone features.

Deferred at: operator intake (post-1.0 planning, 2026-07-14).

### Workspace Canvas Snapshot / Undo / Time-Travel

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: hold

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

### Multi-User Collaborative Plan Editing

Class: Won't-now (confirmed 2026-07-14) · Effort: L

Status: parked. Added in the post-v0.43 planning pass.

v0.44 Plan/Build is single-user: one operator authors and approves a
plan; expand-to-fullscreen edits happen in one LiveView session at a
time. Concurrent editing of a shared plan preview (multiple operators
seeing each other's edits live) requires v0.23's reserved Cursor
concept (multi-user collaborative cursor) plus a conflict-resolution
story. Defer until hosted multi-user authorization (also parked) is on
the table.

### Drag-Drop Tile Reordering / Resize / Durable Layout

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: hold — polish; the first-run mandate is simplification

Status: verify.

Deferred from v0.26: drag-drop tile reordering, tile resize, and a durable
per-canvas layout, plus the related StockSage card-arrangement work noted in
ADR 0023 and the roadmap.

Deferred at: `v0.26-plan:2071`, `adr/0023:583`, `roadmap:1724`.

### Multi-Canvas-Per-Thread

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked.

One canvas per thread today; ADR 0023 and the v0.26 plan both defer multiple
named canvases per thread.

Deferred at: `adr/0023:584`, `v0.26-plan:2074`.

### Theme File-Watcher Live Reload

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold

Status: parked.

ADR 0025 defers a file-watcher that live-reloads operator theme files on
change (today a restart or manual reload picks up edits).

Deferred at: `adr/0025:172`.

### Per-Identity Theme Scope

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold

Status: parked.

v0.61b deferred scoping themes per identity (different theme per operator
identity/persona) rather than globally.

Deferred at: `v0.61b-plan:1643`.

### Mobile-Ready Web UI/UX → Lightweight Native Mobile App

Class: Must (confirmed 2026-07-18) · Effort: L · Slice: horizon (placed at the next ladder review; stage 1 may ride an earlier minor as non-flagship scope on operator direction)

Status: operator intake 2026-07-18.

Mobile-ready UI/UX for the web workspace, staged so the mobile-ready
frontend can later be encapsulated into a lightweight native mobile app
that calls APIs. That end-state may require readying the backend with API
endpoints for remote-or-local frontend↔backend connectivity, including
user auth for the remote path.

Rough decomposition (stages, each independently valuable):
1. **Mobile-ready web UI/UX** — first-class phone-form-factor workspace
   (the existing mobile tabs/responsive work as the base; the parked
   Dynamic Mobile Breakpoints entry folds in here as an enabler).
2. **API surface readiness** — the frontend↔backend contract exposed as
   stable API endpoints usable by a non-LiveView client (interacts with
   the Public Protocols & Interop surfaces; local-first remains the
   default posture).
3. **User auth for remote connectivity** — authenticated remote
   frontend→backend access (today's posture is local-single-operator;
   remote auth is a new authority surface and needs its own ADR; relates
   to the parked non-local bind hardening item on the 1.3 horizon).
4. **Lightweight native shell** — the mobile-ready frontend wrapped as a
   native app calling those APIs (distinct from the parked desktop
   packaged-GUI cluster under Packaging & Distribution, which stays
   parked).

Provenance: operator intake, 2026-07-18 (v1.0.2 M8 window).

### Dynamic Mobile Breakpoints

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold — folds into the
Mobile-Ready Web UI/UX intake (stage 1 enabler) if/when that is slotted

Status: parked.

v0.26 deferred dynamic (content-aware) mobile breakpoints for workspace
layout.

Deferred at: `v0.26-plan:683`.

### Canvas.Agent Revisit

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold — revisit only with new canvas features

Status: parked.

v0.26 flagged Canvas.Agent for a design revisit that never happened.

Deferred at: `v0.26-plan:175`.

### Workspace Zone/Destination Naming Evolution

Class: Closed (confirmed 2026-07-14) — a freeze carve-out (naming freedom), not scheduled work

Status: parked.

The v1.0 plan notes the workspace zone/destination naming has a single
consumer and should evolve when a second consumer appears.

Deferred at: `v1.0-plan:293`.

### Surface DSL Additive Components Carve-Out

Class: Closed (confirmed 2026-07-14) — additive-as-needed alongside features; no standalone milestone

Status: parked.

The v1.0 plan defines a carve-out for adding new Surface DSL components
additively post-1.0 without reopening the frozen contract; the first use of
that carve-out (and its gate wiring) is future work.

Deferred at: `v1.0-plan:229`.

### Plugin Workspace-Region Graduation Confirm

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: quick verify (did v0.31 graduate plugin regions?), then close

Status: verify.

The v0.26 plan says the plugin workspace-region contribution was graduated in
v0.31; the sweep could not confirm the graduation shipped.

Deferred at: `v0.26-plan:2079`.

## Models & Memory

### Long-Term User Memory (Periodic Consolidation, Prompt-Time Context)

Class: Must (confirmed 2026-07-14) · Effort: L · Slice: 1.1 CO-FLAGSHIP — research phase first

Status: parked (operator-directed, post-1.0 intake 2026-07-14).

The user-facing sibling of Adaptive Usage Profiling (Self-Improvement
category): over time, build a **long-term user memory** that remembers facts
about the user's personal life and preferences, **periodically consolidated by
the system from user interaction history** — not only from explicit "remember
this" asks. At prompt-formation time this memory is consulted to assemble
proper context for the LLM, so answers land **zero-shot**: the stated goal is
shortening token usage and interaction count by giving the model the right
context up front instead of re-deriving it conversationally.

**Research phase required before promotion**: survey short-term vs long-term
memory vs usage-history architectures (working/episodic/semantic splits,
consolidation cadence, decay/refresh policies, retrieval-at-prompt-time
budgets) and how they map onto the shipped substrate — v0.39b Active Memory
(deterministic recency-weighted lexical retrieval over reviewed `:kept`
entries), the memory namespaces, and the review surface. Output should be a
research note under `docs/research/` feeding the promotion ADR.

Consent boundary to resolve at promotion (needs an ADR): the trust spine says
"memory review remains explicit", and the v0.24 non-goal "no automatic memory
promotion" (triage table) is exactly this feature. The staged posture:
system-consolidated memories land as **reviewable drafts** (or a distinct
"system-proposed" tier the operator can bulk-accept), and only reviewed
entries become prompt context — or the ADR consciously relaxes the explicit-
review line for a bounded fact/preference class. Silent accumulation into
prompts is not the default.

Related: Adaptive Usage Profiling (system-usage half of the same loop — the
suggest job reads both memories); System Memory Distillation (the parked
learned/model-trained variant — this entry is the deterministic/consolidated
route); Cross-Thread / Cross-App Memory Retrieval (retrieval scope);
Embedding-backed retrieval note under Distillation (semantic recall).

Folded in (operator decision 2026-07-14): the v0.14 working-memory contract
gaps - a precise data-safety definition for working memory and nested patch
semantics for working-memory updates (`v0.14-plan:390`, `v0.14-plan:249`) -
resolve inside this feature's research phase (short-term memory IS the
working-memory tier of the STM/LTM architecture question).

Deferred at: operator intake (post-1.0 planning, 2026-07-14).

### System Memory Distillation

Class: Must-candidate (confirmed 2026-07-14; co-flagship candidate for the 1.2/1.3 horizon, after the deterministic adaptive loop proves out) · Effort: L

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

The v0.31–v0.40 sweep confirms embedding-backed Active Memory retrieval and
memory pinning are also parked under this entry (no separate section).

### Cross-Thread / Cross-App Memory Retrieval

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: foundational input to the Long-Term User Memory research phase (retrieval scope) — research to confirm

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

### Conversation History Full-Text Search

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: foundational input to the Long-Term User Memory research phase (retrieval substrate) — research to confirm

Status: parked. Added in the post-v0.37 planning pass.

Markdown memory has full-text search through v0.21. SQLite `Thread`/`Message`
conversation history does not. Operators may want to search prior threads.

Still parked:

- SQLite FTS5 over Message bodies;
- per-user and per-app filter;
- redaction-aware indexing;
- thread context retrieval into Active Memory (related to "Cross-Thread /
  Cross-App Memory Retrieval" above).

### Model Fallback / Degradation Policy

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: 1.1 — required by the zero-click detect states

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

### Post-v0.48 Media Follow-Ons

Class: Won't-now (confirmed 2026-07-14) · Effort: L

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

### OAuth-Authenticated Hosted LLM Providers (Subscription Plans)

Class: Should (operator intake 2026-07-15) · Effort: M · Slice: 1.4/1.5 enabler train (independently valuable before the 2.0 self-hosting flagship)

Add Claude, OpenAI (Codex), and Gemini as hosted providers via **OAuth
sign-in**, not only API keys — so an operator's monthly/yearly packaged
pro/subscription plan powers Allbert instead of metered keys. Needs: OAuth
device/browser flows per provider, refresh-token custody in the existing
three-tier vault (OS keychain first), provider-ToS review per plan type, and
model-catalog integration so these appear as selectable profiles. Feeds the
adaptive loop's "suggest a BYOK/hosted coding model" one-click path and the
2.0 self-hosting flagship (developer-grade models on subscription plans).

Deferred at: operator intake (post-1.0 planning, 2026-07-15).

### Model Chooser / Catalog

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: 1.1 — enabler for zero-click and adaptive suggestions

Status: parked.

v0.64 deferred a model chooser/catalog surface (browse available models with
size/capability metadata instead of typing a model id). High-value first-run
and profile-switching UX.

Deferred at: `v0.64-plan:171`.

### Per-Role Fast/Capable/Thinking Model Profiles

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: 1.1 — the target surface of adaptive model suggestions

Status: parked.

v0.37 deferred per-role model profiles (a fast model for ranking, a capable
model for main responses, a thinking model for planning) instead of one
profile per intent.

Deferred at: `v0.37-plan:229`.

### Free-Form Provider URLs / Probe Targets Via Approval Path

Class: Should (confirmed 2026-07-14) · Effort: S · Slice: 1.2 horizon — LAN/self-hosted model endpoints via the external-network approval path

Status: parked.

v0.39 deferred letting operators add free-form provider URLs and probe
targets through the approval path (the provider list is curated today).

Deferred at: `v0.39-plan:207`.

### Separate Active Memory Consumer When Direct-Answer Disabled

Class: Closed (confirmed 2026-07-14) — superseded by Zero-Click First Run (direct answers become the default)

Status: parked.

v0.39b deferred a separate Active Memory consumer path for the case where
direct-answer is disabled.

Deferred at: `v0.39b-plan:175`.

### Local Ollama Multimodal Profile

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold (1.4-or-later horizon)

Status: verify.

The v0.49 media work left it unclear whether a local Ollama multimodal
profile is supported end-to-end for image understanding.

Deferred at: v0.49 plan/readiness notes (sweep-flagged, no single line ref).

## Agents & Workflows

### Asynchronous Background Agent Fan-Out With In-Channel Steering

Class: Must (confirmed 2026-07-18) · Effort: L · Slice: 1.1 flagship (operator-slotted 2026-07-18; ladder renumbered — zero-click → 1.2, user memory → 1.3, profiling → 1.4, enablers → 1.5/1.6)

Status: planned — `docs/plans/v1.1-plan.md` (initial plan committed 2026-07-18; triad: plan + request-flow + ADR 0083/0084/0085).

The runtime must support asynchronous background agents that can be run and
controlled via the channel — whatever the channel (TUI, web, Telegram, …).
When a user gives a prompt and Allbert determines (plausibly via the intent
engine) that it decomposes into multiple small tasks, Allbert kicks off
multiple agents/actions behind the scenes, continuously communicates with
them for status, waits for all to complete, and reports back — per user
instruction or default behavior — to the originating channel. The channel
stays open for user communication throughout. If the user adds input while
agents are running, Allbert determines from context whether it applies to
the in-flight agent jobs (steer/adjust/cancel) or is a new independent
request, and acts accordingly.

Decomposes roughly into: intent-engine multi-task decomposition; concurrent
fan-out over the delegate-agent substrate (`Objectives.AgentRegistry`,
`:delegate_agent` steps) with join/aggregation semantics; continuous
status/progress streaming to the originating channel (builds on the v1.0.1
`source_channel`/`source_surface` objective attribution); non-blocking
channel turns while jobs run; and mid-flight follow-up disambiguation
(steering vs new request) in the intent pipeline.

Provenance: operator intake, 2026-07-18 (v1.0.2 M8 window).

### Agent URI Execution And Broader Agent Endpoints

Class: Could (confirmed 2026-07-14) · Effort: L · Slice: hold

Status: parked.

v0.40 plans MCP client execution. Future `agent://` and `agent+https://`
endpoint execution remain parked.

Still parked:

- remote agent endpoint discovery and authentication;
- cross-scheme grant policy for agent resources;
- remote agent impersonation defenses;
- channel-native Approval Handoff for agent endpoints.

### Operator-Authorable And Third-Party Delegate Agents

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

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
  future release with more consumers may (deferred at: `v0.46-plan:126`,
  `v0.46-plan:150`);
- **remote or distributed delegate agents** — covered by "Agent URI
  Execution And Broader Agent Endpoints" above;
- **delegate-agent marketplace distribution** — covered by the
  marketplace governance and "Remote Workflow Distribution" entries.

### Workflow YAML Loops And Parallel Fan-Out

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — folded consideration under Adaptive Usage Profiling stages (suggested automations drive workflow-vocabulary needs)

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

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — folded consideration under Adaptive Usage Profiling stages (suggested automations drive workflow-vocabulary needs)

Status: parked. Added in the post-v0.43 planning pass.

v0.44 workflow YAML cannot reference another workflow as a step. The
`include:` / `import:` composition primitive expands the schema surface
by 3-4x (composition semantics, cycle detection across workflows,
version pinning for included workflows). Reserved as
`sub_workflow_include` in ADR 0041. Defer until a real consumer
appears - possibly after v0.47 self-improvement trace-to-workflow drafts
start producing reusable sub-pieces.

### Auto-Triggered Workflows (`on:` Clauses)

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — folded consideration under Adaptive Usage Profiling stages (suggested automations drive workflow-vocabulary needs)

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

### Workflow Retry/Backoff, `env:`, And ask_user-On-Error

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — folded consideration under Adaptive Usage Profiling stages (suggested automations drive workflow-vocabulary needs)

Status: parked.

v0.44 deferred per-step retry/backoff policy, an `env:` block, and an
ask_user-on-error handler for workflow YAML; all sit in ADR 0041's reserved
vocabulary alongside the loop/fan-out kinds above.

Deferred at: `v0.44-plan:167`, `v0.44-plan:436`.

### Per-Objective ACL Scoping

Class: Could (confirmed 2026-07-14; demoted — multi-user is Won't-now) · Effort: M · Slice: hold

Status: parked.

v0.24 deferred scoping ACLs per objective (which actions/resources a given
objective may touch) rather than per app.

Deferred at: `v0.24-rf:79`.

### LLM-Assisted Acceptance Evaluator

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — revisit with adaptive stage (c) effectiveness scoring

Status: parked.

v0.24 deferred an LLM-assisted evaluator for objective acceptance criteria
(deterministic checks only today).

Deferred at: `v0.24-plan:2589`.

### StockSage Objective-Framing Generalization

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked.

v0.33 deferred generalizing StockSage's objective-framing pattern for other
apps.

Deferred at: `v0.33-plan:507`.

### StockSage TradingAgents Prompt Adaptation (License-Gated)

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold (license-gated)

Status: parked (license-gated).

ADR 0022 defers adapting TradingAgents prompts for StockSage pending a
license review; v0.25 separately deferred the verbatim-prompt license audit.

Deferred at: `adr/0022:429`, `v0.25-plan:1045`.

### FetchSentiment Live APIs (StockTwits + Reddit)

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked.

v0.25 deferred wiring FetchSentiment to live StockTwits and Reddit APIs
(fixture-driven today).

Deferred at: `v0.25-plan:1197`.

### Deeper Native/Python Parity Tuning

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold

Status: parked.

v0.25 deferred deeper parity tuning between the native Elixir analytics and
the Python reference implementation.

Deferred at: `v0.25-rf:652`.

### ADR 0021 Reserved Abstractions & Advisory-Provider Vocabulary

Class: Won't-now (confirmed 2026-07-14) · Effort: L — the adaptive loop may become the first AdvisoryProvider consumer that un-reserves this

Status: verify.

ADR 0021 reserves abstractions with no implementation: world-model,
capability-inventory, diffusion, and market-allocator concepts (v0.24), plus
the advisory-provider vocabulary awaiting its first implementation (v1.0
plan; the v0.21–v0.30 sweep confirms advisory-provider extraction as parked).
Reserved vocabulary only — build nothing until a real consumer appears.

Deferred at: `v0.24-plan:2581-2586`, `v1.0-plan:284-292`.

## Public Protocols & Interop

### MCP Apps Iframe Model

Class: Won't-now (confirmed 2026-07-14) · Effort: L

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

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

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

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

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

### Public UI Protocol Interop Remainder

Class: Won't-now (confirmed 2026-07-14) · Effort: L

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

### Native Plugin Variants For Calendar / Mail / GitHub (Post-1.0 Follow-On)

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

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

### MCP 2025-11-25 Spec Parity

Class: Should (confirmed 2026-07-14) · Effort: M · Slice: 1.1 — verify the actual spec delta first

Status: verify.

Both ADR 0044 and the v0.51 plan note the shipped MCP client/server target an
earlier spec revision; parity with the 2025-11-25 MCP spec was deferred.

Deferred at: `adr/0044:38`, `v0.51-plan:100`.

### MCP/OpenAI/ACP Upstream-Tracking Wire Shapes

Class: Closed (confirmed 2026-07-14) — posture statement (upstream-tracking), not scheduled work

Status: parked.

The v1.0 plan records that the MCP/OpenAI/ACP wire shapes track upstream
protocols and will need periodic reconciliation releases as those protocols
move.

Deferred at: `v1.0-plan:299`.

### Non-Local Bind Hardening For Public Surfaces

Class: Should (confirmed 2026-07-14) · Effort: S · Slice: 1.2 horizon

Status: parked.

v0.51 public surfaces bind local-only; the hardening story for a non-local
bind (auth, TLS, exposure policy) was deferred.

Deferred at: `v0.51-plan:305`.

### MCP Artifact Resources

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold (verify)

Status: verify.

The v0.51 pass left open whether Capsule artifacts should be exposed as MCP
resources.

Deferred at: v0.51 plan notes (sweep-flagged, no single line ref).

### OpenAI/ACP Non-Text Media Blocks

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold (verify)

Status: verify.

The v0.51 OpenAI-compatible and ACP surfaces are text-only; non-text media
blocks (images, audio) were left open.

Deferred at: v0.51 plan notes (sweep-flagged, no single line ref).

## Self-Improvement & Dynamic Capability

### Self-Hosting Development (Allbert Develops Allbert)

Class: Must-candidate (operator intake 2026-07-15) · Effort: XL · Slice: 2.0 horizon (post-1.3/1.4); sub-capabilities may land in earlier trains

Allbert as the development environment for itself, for an Allbert developer:
the workflow the operator runs today with an external assistant — planning
LLM, developer LLM, tester, documenter roles over this repo — runs directly
inside Allbert, via TUI, web workspace, or any channel, likely as a pi-mode
target pointed at the Allbert checkout. Supervised, operator-driven
development (plan → build → test → document with confirmations), NOT
autonomous self-modification: the Won't-now self-recompilation boundary
stays; this is Allbert as agent-harness/IDE for its own codebase. Builds on
pi-mode (ADR 0068 coding trust tier), plan/build, delegate agents, and the
v0.47 supervised-draft machinery. Freeze note: release.v1 must stay green
under any self-hosted change flow — the gates become part of the loop.

Sub-capability (separately shippable, earlier train): OAuth-Authenticated
Hosted LLM Providers (Models & Memory).

Deferred at: operator intake (post-1.0 planning, 2026-07-15).

### Adaptive Usage Profiling & One-Click Customization Suggestions

Class: Must (confirmed 2026-07-14) · Effort: L · Slice: 1.1 CO-FLAGSHIP — stages (a) substrate+distill, (b) suggest+apply (+ proactive notifications), (c) feedback

Status: parked (operator-directed, post-1.0 intake 2026-07-14).

A **system memory** distinct from user/operator memory: the system records its
own construct usage (which intents route, which actions/apps/surfaces/models
are invoked, how often, with what outcomes) as the operator uses Allbert. Two
scheduled jobs close the loop:

1. **Distill (small cadence)** — e.g. after every ~N operator invocations,
   categorize and summarize raw usage into the system-memory namespace.
2. **Suggest (large cadence)** — analyze the distilled usage **plus the
   user/operator memory** and produce *suggestions* that tune the system to
   respond more accurately in fewer interactions. Every suggestion is a
   **one-click / one-action apply** — a registered, confirmed action that
   takes effect for the next invocation.
3. **Feedback** — a mechanism to learn whether an applied customization
   actually helped (accept/dismiss/undo signals at minimum; effectiveness
   scoring against subsequent usage).

Operator-supplied examples of the suggestion vocabulary:

- Frequent web searching → raise web-search intent priority.
- Frequent coding asks → configure a stronger coding model profile (up to
  suggesting a BYOK hosted LLM) and make pi-mode the default.
- Web research + note-taking pattern → suggest scaffolding a custom
  note-based research app (in the StockSage spirit, via the templated
  creation path).
- A thing the operator asks to do repeatedly → auto-draft a skill that knows
  it (through the v0.47 supervised-draft path).

Builds on shipped precursors rather than replacing them: the v0.39b inert
`identity` system-memory namespace, the v0.47 trace-derived supervised draft
suggestions, the v0.56 learned-review miner (shipped inert), the jobs
scheduler, and templated creation. Authority posture is unchanged: system
memory is inspectable via the memory review surface, suggestions are traced,
and apply is always operator-approved — this is the supervised middle path
between today's static profiles and the parked full-autonomy cluster (see
System Memory Distillation, Autonomous Skill Creation, Learned-Review
Autonomous Producers — this entry is the staged, consented route toward
them). Likely decomposition when promoted: (a) system usage-memory substrate +
distill job; (b) suggestion engine + one-click apply surface; (c) feedback/
effectiveness loop.

Folded in (operator decision 2026-07-14): the v0.39b-named
`operator_settings_memory` system namespace (`v0.39b-plan:105`) is a named
deliverable of stage (a) — the usage-memory substrate reuses the shipped
system-namespace mechanism.

Deferred at: operator intake (post-1.0 planning, 2026-07-14).

### Autonomous Skill Creation Beyond Supervised Drafts

Class: Folded (2026-07-14) into Adaptive Usage Profiling — its supervised-draft path is the consented route; this body preserved as the later-stage horizon record (1.2/1.3)

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

Class: Folded (2026-07-14) into Adaptive Usage Profiling — same supervised later-stage horizon; body preserved

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

### Deeper Sandbox Tiers

Class: Won't-now (confirmed 2026-07-14) · Effort: L

Status: parked.

v0.36 implements a narrow Elixir/OTP sandbox/gate path for generated drafts.

Still parked:

- broader local container sandboxing for arbitrary workflows;
- microVM or remote sandbox execution;
- untrusted scripts/package installs under stronger isolation;
- hosted or multi-user sandbox isolation.

### Scripting Engine Interface

Class: Won't-now (confirmed 2026-07-14) · Effort: L

Status: parked.

v0.09 runs trusted inventoried skill scripts through `run_skill_script`. No
general scripting engine is planned.

Still parked:

- Lua, Python, JavaScript, or other embedded scripting runtime;
- dependency bootstrap policy;
- untrusted-script execution model.

### Generated Custom Phoenix Components / LiveViews / Routes Allowlist

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — v0.37/38 codegen remainder

Status: parked.

v0.37 deferred a reviewed allowlist path for generated custom Phoenix
components, LiveViews, and routes (generated UI is catalog-bound today).

Deferred at: `v0.37-plan:428`.

### Generated UI Declarative Surface

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — v0.37/38 codegen remainder

Status: verify.

v0.37 sketched a declarative Surface for generated UI that may now overlap
the shipped validated Surface DSL.

Deferred at: `v0.37-plan:426`.

### Dynamic Confirmation Resume Adapters For Generated Actions

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — v0.37/38 codegen remainder

Status: verify.

v0.37 left open confirmation resume adapters for dynamically generated
actions.

Deferred at: `v0.37-plan:461`.

### Atomic Supersede Without Intermediate Rollback

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — v0.37/38 codegen remainder

Status: parked.

v0.37 deferred an atomic supersede operation for generated capabilities
(replace without passing through an intermediate rolled-back state).

Deferred at: `v0.37-plan:495`.

### Generic `mix allbert.gen.<pattern>` Dispatch

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — v0.37/38 codegen remainder

Status: parked.

v0.38 deferred a generic generator dispatch (`mix allbert.gen.<pattern>`)
over the shipped fixed set of generators.

Deferred at: `v0.38-plan:147`.

### Reviewed Plugin-Scaffold Path vs `codegen_scaffold`

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: verify-close (likely answered by v0.57)

Status: verify.

v0.47b's reviewed plugin-scaffold path may duplicate or be superseded by the
v0.57 `codegen_scaffold` mechanism; needs a dedupe decision.

Deferred at: `v0.47b-plan:172`.

### Learned-Review Autonomous Producers

Class: Won't-now (confirmed 2026-07-14) · Effort: M — revisit at the 1.2/1.3 distillation horizon

Status: verify.

v0.56 shipped the learned-review substrate with the miner inert; autonomous
producers (anything generating review candidates without an operator in the
loop) were deferred and belong with the autonomy cluster above.

Deferred at: `v0.56-rf:37`.

### Auto Memory Promotion From Objective Observations

Class: Folded (2026-07-14) into Long-Term User Memory — the reviewable-drafts path is the consented version; this body preserved as the unconsented-variant boundary record

Status: verify.

v0.24 sketched automatic memory promotion from objective observations. The
supervised v0.47 draft path covers the reviewed variant; the automatic
variant stays with the autonomy cluster.

Deferred at: `v0.24-plan:2590`.

## Browser & Content

### Broad Office, Archive, And Unknown-Binary Extraction

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

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

Class: Could (confirmed 2026-07-14) · Effort: L · Slice: hold

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
- Windows / WSL2 driver support (the v0.43 plan floated a v0.43.x
  follow-up that never happened — verify whether that promise stands or
  folds into the Tier-2 platform posture);
- JavaScript evaluation actions (`evaluate_js`, `add_init_script`,
  `expose_function`) — deferred at: `v0.43-plan:786`;
- WebSocket, service worker registration, push notifications, background
  sync, geolocation, microphone, camera, or clipboard access from the
  browser plugin;
- recursive crawling, sitemap traversal, or automated link following;
- broad upload (multipart file POST) beyond a future explicitly opted-in and
  confirmed `:browser_form_fill` flow.

Each widens the v0.43 trust posture and needs its own policy, storage,
redaction, and eval story before re-entry.

### XPath Selectors

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold

Status: parked.

v0.43 browser actions accept CSS selectors only; XPath selector support was
deferred.

Deferred at: `v0.43-plan:540`.

### Browser Artifact Cache Lifecycle / Sweep Policy

Class: Should (confirmed 2026-07-14) · Effort: S · Slice: hold

Status: parked.

v0.50 deferred a lifecycle/sweep policy for the browser artifact cache
(unbounded growth today until manual cleanup).

Deferred at: `v0.50-plan:614`.

### Capsule Pluggable Artifact-Store Backend (S3)

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: verify.

v0.50 and ADR 0053 both note a pluggable artifact-store backend (S3 or
similar) as a possible future; ADR 0053 self-parks it.

Deferred at: `v0.50-plan:54`, `adr/0053:45`.

## Marketplace & Ecosystem

### Code-Bearing Remote Plugin Distribution

Class: Could (confirmed 2026-07-14) · Effort: L · Slice: hold

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

The v0.56–v0.62 sweep confirms packaged-install plugin-code loading (the
v0.62 packaged binary loading external plugin code) is also parked under this
entry.

### Marketplace Community Submission / Review Governance

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked. Added in the post-v0.37 planning pass.

v0.45 marketplace lite ships single-vendor (Allbert-author seed bundles
only). A submission/review process for community contributions requires:

- submission workflow (PR against an index repo? hosted form?);
- reviewer ownership and rotation policy;
- revocation / takedown process;
- provenance + signing requirements for community submissions;
- trust-tier for community-reviewed vs Allbert-author-reviewed bundles.

Promote post-1.0 when the project decides on governance.

### Remote Workflow Distribution / Marketplace Workflows

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

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

### Plugin Auto-Update Story

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: parked. Added in the post-v0.37 planning pass.

Reviewed plugins (Allbert-author and, post-1.0, community-submitted) will
release new versions over time. v0.45 marketplace ships single-snapshot
catalogs; updating means upgrading Allbert.

Still parked:

- version pinning per plugin;
- reviewed-upgrade workflow;
- rollback after a regression;
- breaking-change deprecation policy for plugin contracts.

### Public Plugin Hook Contribution API

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

Status: verify.

v0.25 sketched a public API for plugins to contribute hooks; the current
plugin contract may or may not cover it.

Deferred at: `v0.25-plan:1571`.

## Ops, Security & Governance

### Hosted Multi-User Authorization

Class: Won't-now (confirmed 2026-07-14) · Effort: L

Status: parked.

Allbert's near-term identity model remains local `user_id`. Hosted accounts,
roles, teams, auth sessions, API keys, and cross-user authorization remain
future work.

### Remote Sync Service

Class: Won't-now (confirmed 2026-07-14) · Effort: L

Status: parked.

v0.59 plans local-first profile export/import dry runs. Broad remote sync
remains parked.

Still parked:

- continuous sync service;
- conflict resolution across machines;
- cloud storage/provider policy;
- shared profile authorization.

### Broader Distributed Operation

Class: Won't-now (confirmed 2026-07-14) · Effort: L

Status: parked.

v0.51 public protocol exposure is local public-surface exposure, not a
distributed runtime.

Still parked:

- complex multi-node operation;
- cluster state replication;
- hosted scheduler/worker coordination;
- distributed confirmation ownership.

### Unified Cost Dashboard And Budget Enforcement

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold — future input to cost-aware adaptive BYOK suggestions

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

### Anonymous Telemetry Policy

Class: Could (confirmed 2026-07-14) · Effort: M · Slice: hold

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

## Housekeeping & Known Debt

### Service-Worker Asset Discovery Follow-On

Class: Could (confirmed 2026-07-15) · Effort: S · Slice: 1.0.x housekeeping

Status: parked.

`workspace-sw.js` retains plain-path `DEFAULT_SHELL_ASSETS` entries while the runtime
asset message adapts to rendered digest URLs. The `app.js` DOM selector also keys on
digested `src` attributes and does not include every equivalent asset-link shape.
Undigested files remain available, so neither detail blocks v1.0.1, but the pair should
be reconciled in a later service-worker cleanup with packaged-cache regression proof.

Deferred at: `v1.0.1-plan` second-pass implementation-readiness audit.

### Legacy `intent.*model_profile` Settings Removal

Class: Should (confirmed 2026-07-14) · Effort: S · Slice: 1.1 — third consumer of the Settings Runtime Migration Runner

Status: verify (blocked on the Settings Runtime Migration Runner for a
non-additive removal).

v0.48 noted the legacy `intent.*model_profile` settings should be removed per
ADR 0046.

Deferred at: `v0.48-plan:441`.

### Optional Git-Hook Installation

Class: Could (confirmed 2026-07-14) · Effort: S · Slice: hold

Status: parked.

v0.45.1 deferred an optional developer git-hook installation step.

Deferred at: the v0.45.1 plan (sweep-flagged, no single line ref).

## Triage Notes

UNCLEAR sweep items needing operator verification before their proposed class
is trusted:

| Item | Category | Verify |
| --- | --- | --- |
| Full Cross-Action Param-Contract Enforcement | Platform & Runtime Debt | What v0.59 shipped vs the full v0.54-plan:1291 scope |
| App-Registry Membership Check At Action Boundary | Platform & Runtime Debt | Whether a boundary check landed after v0.15 |
| Working-Memory Contract Gaps | Platform & Runtime Debt | Whether the v0.14 data-safety/nested-patch gaps still apply |
| Packaging-Trust Re-Parked Exceptions (ADR 0076) | Packaging & Distribution | Which exceptions remain after v0.64–v1.0 trust work |
| Rich TUI Onboarding Slash-Command Wizard | Packaging & Distribution | Whether v0.64's first-run TUI subsumed it |
| Native Windows Packaging | Packaging & Distribution | Demand vs keeping Tier-2 WSL2-only |
| Bundled Executable Packaging For Capability Helpers | Packaging & Distribution | Whether the v0.62 packaged binary covers it |
| Drag-Drop Tile Reordering / Resize / Durable Layout | Workspace & Web UI | StockSage cards scope (adr/0023:583 vs roadmap:1724) |
| Plugin Workspace-Region Graduation Confirm | Workspace & Web UI | Whether v0.31 actually graduated it |
| `operator_settings_memory` System Namespace | Models & Memory | Whether shipped settings/memory surfaces cover it |
| Local Ollama Multimodal Profile | Models & Memory | Whether it works end-to-end against the v0.49 bridge |
| ADR 0021 Reserved Abstractions & Advisory-Provider Vocabulary | Agents & Workflows | Whether any consumer has materialized |
| MCP 2025-11-25 Spec Parity | Public Protocols & Interop | Actual gap vs the shipped MCP surfaces |
| MCP Artifact Resources | Public Protocols & Interop | Whether wanted; grant story |
| OpenAI/ACP Non-Text Media Blocks | Public Protocols & Interop | Demand + upstream spec shape |
| Generated UI Declarative Surface | Self-Improvement & Dynamic Capability | Whether the shipped Surface DSL covers it |
| Dynamic Confirmation Resume Adapters | Self-Improvement & Dynamic Capability | Whether any generated action needs one |
| Reviewed Plugin-Scaffold Path vs `codegen_scaffold` | Self-Improvement & Dynamic Capability | Dedupe against v0.57 codegen_scaffold |
| Learned-Review Autonomous Producers | Self-Improvement & Dynamic Capability | Miner status; supervision posture |
| Auto Memory Promotion From Objective Observations | Self-Improvement & Dynamic Capability | Relationship to v0.47 supervised drafts |
| Windows / WSL2 Browser Driver Support | Browser & Content | Whether the v0.43.x promise stands (see the authenticated-browser entry) |
| Capsule Pluggable Artifact-Store Backend (S3) | Browser & Content | Any demand; ADR 0053 self-parked |
| Public Plugin Hook Contribution API | Marketplace & Ecosystem | Whether the current plugin contract suffices |
| Legacy `intent.*model_profile` Settings Removal | Housekeeping & Known Debt | Whether the legacy keys still exist |
| Web `external_runtime_serial` Fast-Local Split | Housekeeping & Known Debt | Whether still needed given current timings |

## Review Cadence

Review this file when closing a roadmap release, adding a roadmap milestone,
running the operator's prioritization pass over the proposed classes, or
discovering repeated operator requests that are not covered by the current
roadmap.

Note: the roadmap carries "Capabilities Parked Post-1.0" (§~4521) and
"Future: Distillation, Autonomy, Distributed Operation" (§~4532) pointer
sections that delegate here — any roadmap restructure must preserve those
pointers.
