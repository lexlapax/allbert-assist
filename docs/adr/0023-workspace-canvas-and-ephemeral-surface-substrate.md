# ADR 0023: Workspace Canvas And Ephemeral Surface Substrate

## Status

Accepted on 2026-05-18 with v0.26 Agentic Workspace Surface And
Ephemeral UI Substrate M20 closeout. This ADR pins the binding
decisions shipped in v0.26 — the foundational UI layer that turns
`AllbertAssist.App.CoreApp`'s declared `/agent` surface into a
signal-driven, declaratively-rendered workspace with a per-thread
canvas of persistent tiles and per-thread ephemeral surfaces.

## Context

v0.18 (Allbert App Contract And Surface DSL, ADR 0015) shipped:

- A declarative `%AllbertAssist.Surface{}` struct with validated
  catalog-driven nodes, action bindings, fallback text, redaction
  rules, and a `SurfaceProvider` behaviour for apps to declare
  surfaces.
- A 12-component catalog (`:route`, `:chat`, `:timeline`, `:composer`,
  `:panel`, `:section`, `:text`, `:list`, `:empty_state`, `:button`,
  `:action_button`, `:status_badge`).
- A `to_a2ui/1` stub that returns `{:error, :not_implemented}` for
  future protocol bridging.

v0.18–v0.25 left the actual workspace rendering at a single
prompt+response page (`AllbertAssistWeb.AgentLive` chat surface).
Sibling LiveViews (`ObjectiveLive`, `JobsLive`, `SettingsLive`) were
added piecemeal as standalone routes; they do not compose into a
unified operator workspace.

The Allbert/Jido vision (`docs/plans/allbert-jido-vision.md` L359–379)
calls for evolution from "prompt box plus settings page into a
signal-driven operator workspace" with a "canvas" (persistent work
surface) and "ephemeral UI" (task-scoped declarative surface,
discarded when no longer useful) — declarative, catalog-bound,
never arbitrary model-generated UI code.

External agentic-UI ecosystems (A2UI, Gemini generative UI, Claude
Live Artifacts, AG-UI, MCP Apps) have converged around 2025–2026 on
the same principle Allbert chose independently: declarative
component trees validated against a curated catalog. v0.26 is the
first milestone where Allbert's substrate becomes operator-visible,
so the binding contract — what a canvas IS, how tiles persist, how
ephemeral surfaces lifecycle, who can emit runtime fragments, how
they're validated, and how the workspace itself self-describes —
needs an ADR.

The user's framing for v0.26 (2026-05-18, fifth validation pass) is
explicit: "this is a crucial, foundational, first stage of the UI
layer ... it needs to be a canvas that can dynamically change ...
don't defer things we can do."

## Decision

### 1. Vocabulary lock-in (v0.26 onward)

| Term | Meaning |
|---|---|
| **Canvas** | The persistent workspace, scoped per v0.12 thread. One canvas per thread; created lazily on first tile addition; dies with the thread (or thread `completed_at` set). |
| **Tile** | A persistent unit inside a canvas. Has stable id, position, size, body content. Renders as a region of the workspace UI. Tiles persist across browser refresh, LiveView reconnect, and tab switches as long as the thread is alive. |
| **Ephemeral Surface** | A task-scoped overlay that appears for a focused interaction (approval card, trace inspector, single-shot prompt). Per-thread (shared across tabs of the same thread), born when an emitter creates it, GC'd when the thread completes or after an explicit dismiss. |
| **Fragment** | The catalog-emitted `%AllbertAssist.Surface{}` struct that becomes a Tile or Ephemeral Surface. Always validated against the v0.18 catalog at emission and rendering time. |
| **FragmentEnvelope** | The bounded wrapper around a Fragment carrying provenance (emitter_id, user_id, thread_id, emitted_at, signature). |
| **Workspace Shell** | The top-level LiveView that walks a root Surface tree to render the workspace. The shell itself is declarative — it's a Surface composed of region nodes that themselves contain Tile + Ephemeral Surface nodes. |

Reserved (named, not implemented in v0.26):

- **Canvas Snapshot** (versioned canvas state for time-travel / undo) — reserved
- **Cursor** (multi-user collaborative cursor) — post-v0.37
- **Workspace Hooks** (plugin-contributed workspace extensions) — graduated in
  v0.32 as panel surfaces + host-owned named zones; see ADR 0024

### 2. Workspace shell IS a Surface tree (fully dynamic)

The workspace shell does NOT have a hardcoded HEEx layout. It renders
by walking a top-level `:workspace` Surface that contains region
nodes (e.g., `:header`, `:chat_region`, `:canvas_region`,
`:tabs_region`). Each region resolves to a LiveComponent that
renders its child nodes.

The workspace Surface tree is itself constructed at LiveView mount
from:

- `AllbertAssist.Workspace.Catalog.workspace_tree/1` — the base
  shell tree (chat region + canvas region + ephemeral region)
- `AllbertAssist.Workspace.Canvas.tiles_for_thread/1` — current
  thread's tiles (rendered into the canvas region)
- `AllbertAssist.Workspace.Ephemeral.surfaces_for_thread/1` —
  current thread's ephemeral surfaces (rendered into the ephemeral
  region)
- Any LiveView state assigns that should appear in the header
  (active user, active objective badge, debug toggles)

Implications:

- Adding a new region requires only a catalog entry + a LiveComponent
  module that knows how to render it. No HEEx layout edit.
- Plugins can contribute regions via `SurfaceProvider.surfaces/0`
  (graduated in v0.32 as `:panel` surfaces targeting host-owned `/workspace`
  zones; see ADR 0024).
- The workspace shell is itself inspectable — `mix
  allbert.workspace inspect` (M2) dumps the resolved Surface tree.

### 3. Per-thread canvas persistence (hybrid SQLite + YAML)

Canvas state persists across browser refresh, LiveView reconnect,
node restart, and tab switches. Storage is hybrid:

- **SQLite**: `workspace_canvas_tiles` table holds tile metadata
  (tile_id, thread_id, user_id, kind, position, size, created_at,
  updated_at, deleted_at, current_revision_id). Indexed by
  thread_id + user_id.
- **SQLite**: `workspace_canvas_tile_revisions` table holds bounded
  browser-originated offline update metadata (`tile_id`,
  `base_revision_id`, opaque `yjs_update` BLOB, optional
  `state_vector` BLOB, text snapshot, origin, conflict count,
  `created_at`). Supports offline edit reconciliation (see §7)
  without requiring Elixir to interpret the Yjs binary format.
- **YAML**: tile body content (the "human-meaningful payload" of a
  tile, e.g., markdown text, structured field map) lives at
  `<ALLBERT_HOME>/workspace/canvas/<user_id>/<thread_id>/<tile_id>.yml`.
  Inspectable, git-able, recoverable if SQLite is lost.

Why hybrid (rejected alternatives below):

- Pure SQLite loses inspectability — `cat .../tile.yml` is the
  operator's debug story.
- Pure YAML loses queryability — `WHERE thread_id = ? AND
  deleted_at IS NULL ORDER BY position` requires SQL.
- ETS-only would lose data on node restart, violating the
  "persistent across navigation" requirement.

Tiles are soft-deleted (`deleted_at`) for forensic recovery; hard
delete is a follow-up operator command (`mix allbert.workspace
canvas purge --before <date>`).

**Cap-exceeded policy: FIFO eviction with pinning.** When a tile
emission would push the per-thread tile count above
`workspace.canvas.max_tiles_per_thread`, the Canvas store evicts
the oldest non-pinned tile (FIFO by `inserted_at`). Eviction is a
soft-delete: SQLite `deleted_at` is set and the body YAML moves to
`<tile-id>.deleted.<ts>.yml` under the same canvas directory; body
content is never destroyed. The `pinned: boolean` column on
`workspace_canvas_tiles` (default `false`) marks tiles exempt from
FIFO eviction. If every tile in the thread is pinned and the cap is
exceeded, `Canvas.add_tile/1` returns `{:error,
:canvas_cap_exceeded}` and the emitter receives the error through
Fragment validation. Each eviction emits
`allbert.workspace.tile.removed` with `removed_reason:
:cap_evicted` and a `:badge_strip` Fragment to the canvas header
("N older tile(s) archived"). Operators recover via
`Workspace.restore_tile/2` (and the CLI mirror
`mix allbert.workspace canvas restore <tile-id>`), which clears
`deleted_at`, moves the YAML back, and places the tile at the end
of the position order.

This makes the cap a soft boundary: operator-visible, recoverable,
discoverable through the canvas header badge, and operator-
controllable via pinning.

### 4. Per-thread ephemeral surfaces, shared across tabs

Ephemeral surfaces are bound to a v0.12 thread, NOT to a LiveView
pid. Multiple tabs viewing the same thread see the same ephemeral
set. Closing a tab does not close the ephemeral surface. Closing the
thread (or thread `completed_at` set, or explicit operator
dismiss) GCs all ephemerals for that thread.

Storage: SQLite `workspace_ephemeral_surfaces` table (thread_id,
surface_id, kind, body_yaml_path, created_at, dismissed_at).
Bounded: 16 active ephemerals per thread (configurable via
`workspace.ephemeral.max_active_per_thread`); over-emission drops
oldest non-pinned ephemeral with a bounded log entry.

Why per-thread instead of per-LiveView-pid:

- Operator views same thread in two tabs → seeing different
  ephemeral states would be confusing.
- Reload → losing the in-progress approval card would be hostile.
- Cross-tab broadcast via Phoenix.PubSub is already cheap (v0.24
  SignalBridge proves the pattern).

Why per-thread instead of per-objective:

- Some ephemerals don't belong to an objective (e.g., a settings
  edit prompt, a memory review). Thread is the broader scope.

Why per-thread instead of per-user:

- "Why did this just appear in my other tab?" UX surprise is
  bounded to "I have the same thread open elsewhere."

### 5. Fragment emission via signal topic, validated by strict + signed envelopes

Runtime fragments (Tiles or Ephemeral Surfaces emitted dynamically
during a turn) flow through the Allbert SignalBus on topic
`allbert.workspace.fragment.**`. Any in-BEAM module can publish to
the topic (registered actions, objective engine, delegate agents,
intent agent, channels — any subscriber).

The `AllbertAssistWeb.SignalBridge` (extended in v0.26 from its
v0.24 form) subscribes to `allbert.workspace.fragment.**`. For each
inbound signal:

1. **Envelope validation**: signal payload MUST be a
   `%AllbertAssist.Workspace.FragmentEnvelope{}` with the documented
   fields (surface, emitter_id, user_id, thread_id, scope
   ("canvas" | "ephemeral"), tile_position (when canvas), kind,
   emitted_at, signature).
2. **HMAC signature verification**: envelope signature is HMAC-SHA256
   of the canonicalized envelope fields, keyed by a Settings Central
   secret (`workspace.fragment.signing_secret`). Signing secret
   default-generated at app boot and persisted in Allbert Home;
   recoverable via `mix allbert.workspace rotate-signing-secret`.
   Rotation keeps the previous key only for a short printed overlap
   window so in-flight Fragments can drain without accepting stale
   signatures indefinitely.
3. **Surface validation**: the wrapped Surface validates via
   `AllbertAssist.Surface.validate_surface/1` against the catalog
   (v0.26 expanded to 42 components per the v0.26 plan).
4. **Emitter authentication**: emitter_id MUST be in a known
   emitter allow-list (registered action module names, the
   objective engine module name, registered delegate agent ids).
   Unknown emitters dropped.
5. **Rate limit**: per-(emitter_id, user_id) rate limit (default
   10 fragments/second; configurable). Over-limit dropped with
   bounded log entry.
6. **Payload size**: envelope (after canonicalization) ≤ 64 KB.
   Over-size dropped.

Valid envelopes broadcast to per-user PubSub topic
`workspace_fragments:<user_id>` as `{:fragment, envelope}`. The
workspace shell LiveView subscribes on mount and applies fragments
to the appropriate region (canvas or ephemeral).

Signing rationale: BEAM is single-trust today, but the signing
contract documents the future v0.31+ multi-process / multi-node
boundary. Costs nothing at single-trust; future-proofs the
authority boundary. The signing secret never leaves Allbert Home
and the operator can rotate it.

Invalid fragments are dropped with a bounded log entry; never
rendered. The drop reason (envelope shape, signature mismatch,
catalog mismatch, unknown emitter, rate limit, oversize) is
captured in trace metadata for the originating turn so operators
can debug.

### 6. v0.26 catalog expansion to 42 components (per amended ADR 0015)

v0.18's 12 components are insufficient for a workspace shell. v0.26
expands the catalog to 42 components in four categories:

**Workspace structural (10)**: `:workspace`, `:canvas`, `:tile`,
`:ephemeral_surface`, `:header`, `:badge_strip`, `:tabs`, `:tab`,
`:tab_panel`, `:diff`.

**Allbert-domain (12)**: `:trace_link`, `:trace_viewer`, `:icon`,
`:link`, `:divider`, `:table`, `:row`, `:column`, `:objective_card`,
`:confirmation_card`, `:approval_card`, `:approval_inspector`.

**Allbert-app cards (4)**: `:memory_review_card`, `:job_card`,
`:channel_card`, `:settings_card`.

**StockSage analysis cards (4 — reserved in v0.26 catalog;
implemented in v0.27)**: `:analysis_card`, `:agent_report_card`,
`:parity_card`, `:debate_round_card`. These are present in the
catalog (so emitters can target them) but the LiveComponent
rendering modules are stubs in v0.26 (render a placeholder + link
to the legacy `/stocksage/analysis/:id` route until v0.27 ships
real cards).

StockSage is a proving plugin, not a workspace dependency. Core
workspace rendering, fragment validation, canvas persistence,
ephemeral surfaces, and offline text editing must pass with the
StockSage plugin disabled.

v0.18 carryover (12): `:route`, `:chat`, `:timeline`, `:composer`,
`:panel`, `:section`, `:text`, `:list`, `:empty_state`, `:button`,
`:action_button`, `:status_badge`.

ADR 0015's v0.26 amendment enumerates the full 42-component
catalog. The amendment also pins the contract that the workspace
shell renders any component in the catalog via a uniform dispatch
table; no component is "internal" — all are catalog-resolvable so
plugins can target any of them via Surface declarations.

### 7. Offline editing via service worker + browser-side Yjs

The workspace canvas supports operator editing while the LiveView
is disconnected (loss of network, browser tab put to sleep). The
implementation:

- **Service worker**: registered at `/agent`. Caches the workspace
  shell assets (JS, CSS, fonts, offline shell fallback). It does
  not treat cached authenticated HTML as durable truth; runtime data
  rehydrates from SQLite/YAML when the LiveView reconnects.
- **Per-tile browser state**: editable text/markdown tile body
  content is represented as a browser-owned Yjs document. Updates
  persist locally through IndexedDB while offline.
- **Reconnect sync**: on reconnect, the browser sends base revision,
  state vector, bounded Yjs update blob(s), and the latest
  text/markdown snapshot. Elixir validates user/thread/tile
  ownership, payload bounds, base revision, and editable tile kind,
  then stores the opaque update blob and snapshot in
  `workspace_canvas_tile_revisions` and the YAML body store.
- **Conflict UX**: when base revisions diverge or multiple offline
  origins edited the same tile, a `Conflict reconciled` banner
  appears on each affected tile with an inspector showing the merge
  history. Operator can revert any reconciled change.

Scope bound for v0.26:

- Offline editing applies ONLY to tile body content of editable
  tile kinds (text, markdown). Non-editable tiles (confirmation
  cards, approval inspectors, trace viewers) are read-only
  offline.
- Ephemeral surfaces are NOT editable offline; they require live
  server state (confirmation approval, trace fetch).
- Service worker is registered ONLY on `/agent` (the workspace
  route). Sibling routes (`/objectives/:id`, `/jobs`, `/settings`)
  remain online-only in v0.26.

CRDT library: ship Yjs (BSD-licensed) and `y-indexeddb` in the web
asset pipeline. v0.26 explicitly does **not** add a server-side Rust
NIF or server-side CRDT interpreter. The server-side module
`AllbertAssist.Workspace.Offline` stores opaque update blobs,
readable snapshots, and conflict metadata; a future milestone may
add server-side compaction or interpretation if an operator-visible
need emerges.

### 8. AG-UI INTERRUPT semantic-mapping bridge (internal, test-only)

The AG-UI protocol (https://docs.ag-ui.com/) defines an `INTERRUPT`
event that maps semantically onto Allbert's confirmation flow
(`allbert.confirmation.requested` → `INTERRUPT`; operator approval
→ `APPROVE` event back). v0.26 ships an internal bridge
`AllbertAssist.Workspace.AGUI.Bridge` that subscribes to
SignalBus and translates a curated subset of Allbert signals into
AG-UI event-shape JSON.

Scope bound for v0.26:

- Bridge is internal-only. NOT exposed over HTTP / WebSocket /
  SSE in v0.26. (Public AG-UI endpoints are post-v0.37 work.)
- Used for two purposes: (1) test the semantic mapping early so
  future external bridge work has a validated contract; (2)
  internal observability — the workspace LiveView can subscribe
  to the AG-UI event stream as an alternative way to render
  confirmation flows.
- Mapping documented at M1 (in this ADR): which Allbert signals
  map to which AG-UI events. The mapping is the binding artifact;
  the code is implementation detail.

Future work (post-v0.37, parked in `docs/plans/future-features.md`):
expose the bridge over SSE or WebSocket; add the inverse direction
(AG-UI client emits events into Allbert as registered-action
calls); validate against an A2UI client.

### 9. Authority posture (unchanged)

Every effectful action triggered from the workspace surface flows
through `AllbertAssist.Actions.Runner.run/3`, Security Central,
confirmations (when needed), and audit, exactly as v0.07/v0.22/v0.24
required. The workspace renders state and dispatches
action invocations through the registered action surface; it does
not own any authority decisions.

Fragment emission is NOT authority. A fragment merely shapes what
the operator sees; clicking a button on a fragment-emitted tile
dispatches an action that re-evaluates Security Central as if the
operator typed the action invocation directly. Fragments cannot
unlock permissions, bypass confirmations, or invent action surfaces
not in the v0.18 catalog. ADR 0015's invariants hold.

### 10. UX qualities for v0.26 (all in scope)

- **Dark mode**: operator-configurable theme via `workspace.theme`
  setting (`"light"`, `"dark"`, `"system"`). Tailwind dark variants.
- **WCAG 2.1 AA accessibility**: keyboard nav (every interactive
  region tab-reachable), ARIA roles + labels on every component,
  screen-reader-tested with NVDA / VoiceOver, focus traps in
  modals, skip-to-content link, contrast-checked color palettes
  (both themes).
- **Mobile responsive**: CSS-only adaptive layout. Above 768px:
  two-pane (chat + canvas) with split bar. Below 768px: single-pane
  with tab toggle between chat and canvas; ephemerals stack as
  full-screen overlays.
- **Offline editing**: browser-side text/markdown tile editing per
  §7.

All four are first-class v0.26 deliverables (operator-runnable per
the milestone smokes); no deferral.

### 11. New permission class: `:workspace_canvas_write`

Operators acting on canvas tiles (add, edit body, dismiss, move)
go through a new Security Central permission class:

- **Class name**: `:workspace_canvas_write`
- **Default policy**: `:allow` (workspace edits are not high-risk;
  effectful actions triggered FROM tiles still go through their
  own per-action permission classes).
- **Safety floor**: `:allow`
- **Risk tier**: `:low`
- **Settings Central key**: `permissions.workspace_canvas_write`
  (writable).

The class exists for symmetry with other `_write` classes and to
provide a future per-user / per-thread ACL hook when hosted
multi-user lands (post-v0.37).

### 12. Settings keys (workspace.*)

v0.26 adds the following Settings Central keys (validation ranges +
defaults documented in `docs/plans/v0.26-plan.md` Settings Central
Schema section):

- `workspace.theme` — `"light"` | `"dark"` | `"system"`; default `"system"`
- `workspace.canvas.max_tiles_per_thread` — int 1..256; default 64
- `workspace.canvas.tile_body_max_bytes` — int 1024..262144; default 65536 (64 KB)
- `workspace.ephemeral.max_active_per_thread` — int 1..64; default 16
- `workspace.fragment.signing_secret` — string (system-managed; rotatable)
- `workspace.fragment.rate_limit_per_second` — int 1..1000; default 10
- `workspace.fragment.receiver_rate_limit_per_second` — int 1..1000; default 10
- `workspace.fragment.payload_max_bytes` — int 1024..262144; default 65536 (64 KB)
- `workspace.offline.enabled` — boolean; default true
- `workspace.offline.indexeddb_quota_mb` — int 1..256; default 32
- `workspace.accessibility.high_contrast` — boolean; default false
- `workspace.accessibility.reduce_motion` — boolean; default false
- `workspace.mobile.breakpoint_px` — read-only positive int; default 768
- `workspace.agui_bridge.enabled` — boolean; default true (internal only; no HTTP exposure)
- `workspace.signal_bridge.log_dropped_fragments` — boolean; default true

### 13. Signal topics (workspace.*)

v0.26 reserves the `allbert.workspace.**` namespace on SignalBus:

| subject | when emitted | payload contract |
|---|---|---|
| `allbert.workspace.fragment.emitted` | Any emitter publishes a FragmentEnvelope | envelope (full structure) |
| `allbert.workspace.fragment.dropped` | SignalBridge validation rejects an envelope | envelope summary + drop_reason + emitter_id + dropped_at |
| `allbert.workspace.tile.added` | Canvas tile persisted | tile_id, thread_id, user_id, kind, position, trace_id |
| `allbert.workspace.tile.updated` | Canvas tile body/position changed | tile_id, thread_id, user_id, changed_fields, trace_id |
| `allbert.workspace.tile.removed` | Canvas tile soft-deleted | tile_id, thread_id, user_id, deleted_at, trace_id |
| `allbert.workspace.ephemeral.opened` | Ephemeral surface persisted | surface_id, thread_id, user_id, kind, opened_at, trace_id |
| `allbert.workspace.ephemeral.closed` | Ephemeral surface dismissed (operator or GC) | surface_id, thread_id, user_id, dismissed_at, dismissed_by, trace_id |
| `allbert.workspace.canvas.snapshot.requested` | Operator requests a canvas snapshot (reserved; no-op in v0.26) | thread_id, user_id, requested_at, trace_id |
| `allbert.workspace.offline.reconciled` | Offline updates accepted and reconciled | tile_id, thread_id, user_id, update_count, conflict_count, reconciled_at, trace_id |

All payloads pass through `AllbertAssist.Security.Redactor.redact/1`
before emission. The v0.22 sensitive-key fragments allowlist
covers these payloads without amendment.

### 14. Trace section additions

The v0.26 trace markdown gains:

- `## Workspace` — top-level section for any turn that emitted at
  least one fragment, opened/closed an ephemeral surface, or
  modified a canvas tile. Contents:
  - Fragments emitted (count, by emitter + kind)
  - Fragments dropped (with reason)
  - Canvas tile mutations (add/update/remove count)
  - Ephemeral surface lifecycle events
  - Offline reconciliation events (if any)
- Inline `### Workspace` subsection — per v0.24 inline placement
  rule, appears under any top-level section that touched the
  workspace.

### 15. Reuse from v0.24 substrate

The v0.24 `AllbertAssistWeb.SignalBridge` GenServer is extended to
subscribe to `allbert.workspace.**` in addition to its existing
`allbert.objective.**` subscription. The bridge's responsibility
broadens: forward objective events to per-user objective topic
(unchanged) AND validate + forward workspace fragment events to
per-user workspace topic. The same per-user topic naming convention
applies.

The v0.24 PubSub topic shape (`<namespace>:<user_id>`) extends:

- `objectives:<user_id>` (v0.24, unchanged)
- `workspace_fragments:<user_id>` (v0.26, new)
- `workspace_tiles:<user_id>:<thread_id>` (v0.26, new — per-thread
  canvas state sync)
- `workspace_ephemerals:<user_id>:<thread_id>` (v0.26, new)

## Consequences

### What changes

- New `AllbertAssist.Workspace.*` module namespace (facade + Canvas
  + Ephemeral + Fragment + FragmentEnvelope + Catalog + Offline +
  AGUI.Bridge).
- New web-side `AllbertAssistWeb.Workspace.*` LiveView + LiveComponent
  modules; transforms `AllbertAssistWeb.AgentLive` into the new
  workspace shell.
- v0.18 catalog expands from 12 to 42 components (ADR 0015 amended
  during v0.26 planning).
- Three new SQLite tables (`workspace_canvas_tiles`,
  `workspace_canvas_tile_revisions`,
  `workspace_ephemeral_surfaces`); one migration in v0.26 M1.
- YAML tile body storage under
  `<ALLBERT_HOME>/workspace/canvas/<user_id>/<thread_id>/`.
- New `:workspace_canvas_write` permission class.
- 15 new `workspace.*` settings keys.
- 9 new `allbert.workspace.**` signal topics.
- Extended `AllbertAssistWeb.SignalBridge` (forward objective +
  workspace topics).
- New `## Workspace` trace section + inline `### Workspace`
  subsections.
- Service worker registered for the `/agent` workspace; browser-side
  Yjs + IndexedDB offline editor bundled in the asset pipeline.
- Internal AG-UI bridge (test-only; no HTTP exposure).
- Workspace shell is itself a Surface tree (dynamic dispatch
  through LiveComponents).
- WCAG 2.1 AA accessibility + dark mode + mobile responsive shipped.

### What stays the same

- `AllbertAssist.Surface` validation contract from v0.18 (struct
  shape, catalog enforcement, redaction rules, fallback text). v0.26
  extends only the catalog allow-list.
- `AllbertAssist.App.SurfaceProvider` behaviour (apps still declare
  surfaces the same way).
- `AllbertAssist.Actions.Runner.run/3` + Security Central +
  confirmations: every effectful action from the workspace flows
  through these.
- Sibling routes (`/objectives/:id`, `/jobs`, `/settings`) stay
  reachable as top-level routes for deep-linking; also become
  reachable as tiles inside the workspace.
- v0.32 supersedes the `/agent` and `/settings` route shape: `/workspace`
  becomes the canonical operator route and Settings Central moves into the
  workspace utility drawer. This is an additive planning amendment to ADR 0023;
  the v0.26 substrate contract remains historical as shipped.
- All v0.07–v0.25 signal topics, settings keys, schemas, and
  acceptance criteria unchanged.

### What's reserved but not implemented in v0.26

- Canvas Snapshot (versioned undo / time-travel) — reserved name only.
- Drag-drop tile reordering — deferred to v0.27+.
- Multi-canvas-per-thread — deferred.
- Cursor (multi-user collaborative cursors) — post-v0.37.
- Plugin-contributed workspace regions — graduated in v0.32 (ADR 0024).
- Public AG-UI HTTP endpoint — post-v0.37.
- A2UI / MCP Apps interop — post-v0.37.
- Offline editing of non-text tile kinds (confirmation card edits,
  trace inspector annotations) — post-v0.27.

## Rejected Alternatives

### Hardcoded HEEx workspace layout

Rejected. A hardcoded layout would require Elixir edits + redeploy
to add a region. The "fully dynamic Surface tree" decision (per
user's design choice) is what enables future plugin-contributed
regions + per-user layout customization without touching the
workspace shell module.

### YAML-only canvas persistence

Rejected. Loses query performance for per-user/per-thread tile
listing + ordering. Operators inspecting "show me all tiles
modified in the last hour across all threads" need SQL.

### ETS-only or in-memory-only canvas

Rejected. Violates the "persistent across navigation" requirement.
Refresh would lose work; restart would lose all canvases.

### Per-LiveView-pid ephemeral surfaces

Rejected. Tested in Round 1 and overridden in Round 2 — multi-tab
sync requires shared identity. Per-thread is the coherent answer.

### Per-user (workspace-global) canvas

Rejected. Conflates conversational context with persistent
workspace. Per-thread keeps the canvas conversational + naturally
GC'd; operators wanting cross-thread persistence get it through
v0.21 memory promotion + future memory namespace browser (v0.27+).

### Per-user (workspace-global) ephemeral surfaces

Rejected. UX-confusing ("why did this appear in my other tab when I
was working on something else?"). Per-thread bounds the surprise.

### Basic catalog-validation-only for fragment emission

Rejected. The widest emission surface (any in-BEAM module) requires
strict validation. The HMAC-signed envelope contract documents the
authority boundary that single-trust-BEAM blurs today and that
v0.31+ multi-process / multi-node will need to enforce.

### Minimal offline (read-only + banner)

Rejected per user's explicit "don't defer things we can do." v0.26
ships real offline text/markdown tile editing. The scope is bounded:
browser-side Yjs + IndexedDB with server persistence of opaque
updates/snapshots, not a server-side CRDT runtime.

### Single ADR for workspace + offline + AGUI + catalog expansion

Rejected. ADR 0023 binds the workspace substrate contract; ADR 0015
amendment binds the catalog expansion contract (which other apps may
target in v0.27+). Two ADRs let each contract evolve independently.

### Public AG-UI HTTP endpoint in v0.26

Rejected. Post-v0.37 work (per Future Features UI Protocol
Interop). v0.26 ships the internal bridge contract; external
exposure waits for a real consumer.

### MCP Apps support in v0.26

Rejected. Allbert's stance is "no arbitrary model-generated HTML/JS"
(vision L369). MCP Apps embraces sandboxed iframes — explicit non-goal
for v0.26. Future work tracks the trust-policy questions.

### Drag-drop tile reordering in v0.26

Rejected. Tile reordering requires JS hooks (HTML5 drag-drop or
SortableJS) and per-tab UI coordination. v0.26 ships resize-bar only
between the chat + canvas regions; tile rearrange is v0.27+ work.

### StockSage renderer vs. durable canvas emission

Clarification from the post-v0.26 roadmap reconciliation: v0.27 and v0.30 are
different contracts. v0.27 renders real StockSage components in
StockSage-owned `/stocksage/...` LiveViews, replacing the v0.26 reserved-card
stubs and validating `RunAnalysis` Surface-node output. v0.30 emits those
proven components into durable `/agent` workspace canvas tiles through
`canvas_ops` and the v0.26/v0.28-audited Fragment/canvas mechanism. v0.32 then
moves StockSage dashboard/list/queue/trend UI into `/workspace` panels and
removes `/stocksage/*` operator routes. This ADR's v0.26 canvas substrate
contract does not change.

## References

- `docs/plans/v0.26-plan.md` (this milestone's implementation contract)
- `docs/plans/v0.26-request-flow.md` (this milestone's runtime/user flow)
- `docs/plans/allbert-jido-vision.md` L359–379 (workspace + canvas + ephemeral vision)
- `docs/plans/project-direction-rethink-01.md` L517–520 (surfaces render, do not own state)
- `docs/plans/future-features.md` UI Protocol Interop section
- ADR 0006 — Security Central
- ADR 0007 — Jido-Native Internal Runtime Boundaries (substrate)
- ADR 0008 — Durable Confirmation Requests
- ADR 0015 — Allbert App Contract And Surface DSL (v0.26 catalog expansion amendment)
- ADR 0017 — Allbert Plugin Contract
- ADR 0019 — Cross-Surface Intent Enrichment
- ADR 0021 — Intent, Objective, Capability, And Advisory Boundary
- ADR 0022 — Native Financial Specialist Agents

External:

- AG-UI Protocol — https://docs.ag-ui.com/introduction
- A2UI specification — https://a2ui.org/specification/v0.9-a2ui/
- MCP Apps SEP-1865 — https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/
- Claude Live Artifacts — https://www.eigent.ai/blog/claude-live-artifacts-guide
- ChatGPT Canvas — https://openai.com/index/introducing-canvas/
- Gemini Generative UI — https://cloud.google.com/discover/generative-ui
- Yjs CRDT — https://docs.yjs.dev/
- Phoenix LiveView Streams (2026 best practice) — Phoenix.LiveView hexdocs
