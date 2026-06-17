# ADR 0054: Artifact Provenance Linking And Browser-Surface Split

## Status

Accepted for v0.50 Artifacts Central provenance linking and for the v0.50b
Artifacts Browser core/plugin split. The linking half shipped in v0.50; the
operator browsing surfaces implement in v0.50b. Amends ADR 0053.

## Context

ADR 0053 establishes the content-addressable artifact store: object layout,
`artifact://sha256/<hex>` identity, dedup, retention, security floors, and the
ingestion sensor. Two follow-on concerns need their own decision:

1. **Provenance.** An artifact should know which conversation (and turn) created
   or referenced it, so an operator can ask "what files came from this thread?"
   and, from an artifact, "which thread produced this?". Content-addressing means
   one `sha256` is legitimately shared across many threads with different roles,
   so the relation is an edge, not a column on the artifact.

2. **Browsing surfaces.** Artifacts Central is meant to be *browsed* like a small
   app (StockSage-style operator surfaces over a local-first record set), via a
   workspace LiveView panel, a deep-linkable detail page, and a CLI. That raises
   a packaging question: what belongs in the core kernel vs. a plugin/app?

## Decision

### Provenance linking

- Links live in a SQLite join table on `AllbertAssist.Repo`:
  `artifact_thread_links(id, artifact_sha256, thread_id, message_id, role,
  user_id, metadata, inserted_at, updated_at)`, `role ∈ {created_by,
  referenced_by}`, indexed on `[:artifact_sha256]` (reverse lookup) and
  `[:thread_id, :user_id]` (browse-by-thread), plus
  `[:user_id, :artifact_sha256]` for scoped reverse lookup.
- Link ids are deterministic from the normalized edge tuple
  `{artifact_sha256, user_id, thread_id, message_id || input_signal_id ||
  "thread", role}`. Repeated puts of the same artifact in the same context
  upsert the same edge instead of creating duplicate browse rows; this avoids
  relying on SQLite unique-index behavior around nullable `message_id`.
- `thread_id`/`message_id` are plain strings, **not enforced foreign keys** —
  consistent with the project stance that thread/objective ids are provenance,
  never authority (objectives, canvas tiles, scheduled jobs all use unconstrained
  indexed `thread_id` string columns). The originating thread/message id is
  additionally denormalized into the artifact's markdown sidecar as bounded
  `provenance` metadata for human-readable provenance (mirrors the trace
  `Thread:` line and the canvas tile sidecar).
- The link is recorded at put-time from the action `context`:
  `request = Map.get(context, :request, %{})`, then `request.thread_id`,
  `request.user_id`, `request.session_id`. Message-level attribution uses
  `request.input_signal_id` (persisted on the `conversation_messages` row),
  resolved by `{user_id, thread_id, input_signal_id}` to a `msg_…` id when
  possible. If the message row is not present, the link remains thread-level
  with `message_id: nil` and `metadata.input_signal_id`; message precision is
  best-effort provenance, not authority.
- Querying is Ecto over the join table (user-scoped, role-filtered), the same
  idiom as `Conversations.list_messages/2` and `Objectives.list_objectives/2` —
  never a markdown scan. SQLite is the index; markdown is the human-facing body.
- A link is provenance, never permission: by-thread listing still resolves
  through `:artifact_read`, and a thread id grants nothing.

### Core kernel vs. plugin surface

- **Core (Artifacts Central, v0.50):** the object store, the `artifact://`
  scheme, the `:artifact_read/:artifact_write/:artifact_delete` permissions and
  operation classes, the `artifacts.*` settings fragment authority, the
  `Runtime.Redactor` artifacts surface, the ingestion sensor, the
  `artifact_thread_links` table, and the registered read/write/query actions.
  These are core because durable Home data must derive from Allbert Home, the
  scheme/permissions/redactor are Security Central + Resource Access concerns,
  and channels (v0.52), MCP (v0.51), and export (v0.58) depend on the store. A
  plugin cannot define a resource scheme, register Security Central permissions,
  add a Home root, or own a sensor over core capture flows.
- **Plugin/app (Artifacts Browser, v0.50b):** the operator browsing repository,
  modeled on StockSage and `allbert.browser`. It implements
  `AllbertAssist.Plugin` + `AllbertAssist.App` + `AllbertAssist.App.SurfaceProvider`,
  contributing: a `:canvas_panels` LiveView **panel** hydrated by
  `workspace_panel_surfaces/1`; an `/apps/artifacts/<sha>` **page** LiveView
  (the route is registered in the core web router, the module is plugin-owned
  and renders through the host `Surface.Renderer`); and a `mix allbert.artifacts`
  **CLI** that is a thin shell over the core `:artifact_read` actions with
  `channel: :cli`. The plugin contributes data only — it renders the store but
  never owns the scheme, permissions, Home root, settings authority, or sensor,
  and acquires no authority (ADR 0017).

## Consequences

- Positive: one canonical provenance model reusing the established
  durable-record→thread pattern; "files from this conversation/turn" and reverse
  lookup are simple indexed queries; the browsing repository dogfoods the
  App/SurfaceProvider contract without bloating core or inverting the
  store-dependency direction; the core release (v0.50) stays shippable while the
  browser lands as a focused v0.50b sidecar.
- Negative: the `/apps/artifacts/<sha>` page route is a small edit to the core
  web router even though the LiveView module is plugin-owned (the web layer is
  host-owned). A panel-only browser would avoid that edit; the page route is
  accepted for deep-linkable detail views.
- Neutral: message-precise linking depends on resolving `input_signal_id` to a
  `msg_…` id; thread-level linking works without it.

## Related

- ADR 0053 (content-addressable artifact store; amended to reference this ADR).
- ADR 0013 (Resource Access URI/grants — the `artifact://` scheme).
- ADR 0006 (Security Central — permissions/operation classes).
- ADR 0031 / 0046 (settings fragment authority / `schema_version`).
- ADR 0015 / 0017 / 0024 (App + Plugin + Surface DSL/panel/page contracts).
- ADR 0023 (workspace canvas / per-thread ephemeral substrate).
- `docs/plans/v0.50-plan.md`, `docs/plans/v0.50-request-flow.md`,
  `docs/plans/v0.50b-plan.md`, `docs/plans/v0.50b-request-flow.md`.
