# ADR 0055: Inbound Public-Surface Trust Tier

## Status

Accepted at v0.51 M1 for Public Protocol Surfaces
(`docs/plans/v0.51-plan.md`).

This ADR is the **inbound** counterpart to ADR 0038 (the outbound MCP *client*
trust tier). ADR 0044 decides *which* public surfaces ship and *what* they
expose; this ADR decides *how Allbert trusts the external clients that reach
those surfaces* — the inbound permission class, per-client authentication,
rate-limiting, the API secure-header posture, and the result-readback exposure.
It also records the v0.51 inbound **text-first protocol subset**: public
protocols may carry richer media/resource payloads, but those payloads are not
permission or capability authority.

## Context

v0.51 exposes Allbert across three public protocol surfaces (ADR 0044): an MCP
server, an OpenAI-compatible HTTP API, and an ACP server. ADR 0038 established an
explicit trust tier for the symmetric *outbound* case (Allbert as an MCP client):
external metadata is never authority, transports are adapters, and a named
permission class with a safety floor gates the boundary. The inbound case needs
the same rigor in the other direction — an external agent calling *into* Allbert
is at least as untrusted as an MCP server Allbert calls *out* to.

Every prior permission class (`:mcp_tool_call`/`:mcp_resource_read` in ADR 0038,
`:voice_*` in ADR 0042, `:artifact_*` in ADR 0053) was introduced by an ADR that
named the class and its safety floor and landed it in
`Security.Policy.permission_classes/0`. The inbound public-surface boundary must
follow that pattern rather than living as plan prose.

Two facts from the v0.51 readiness sweep shape this decision:

- **There is no authenticated HTTP API today.** The web `:api` pipeline is unused
  (the `/api` scope is commented out); everything is LiveView/session-based. There
  is no inbound rate-limiter anywhere. The only token-auth precedent is
  `AllbertAssist.Voice.LocalRuntime.Auth` (a per-Allbert-Home loopback capability
  token using `Plug.Crypto.secure_compare`) — a reusable *pattern*, not the
  Settings-Central-issued per-client token this tier needs.
- **There is no post-approval result-readback path for a stateless external
  client.** Today `approve_confirmation` re-runs a resumable action and returns
  the result to the *operator* who approved; the result persists only in the
  confirmation record, and the read-by-id actions (`show_confirmation`/
  `list_confirmations`) are `exposure: :internal`. A stateless MCP/OpenAI/ACP
  client therefore has no way to retrieve the result of a confirmation-gated
  call. v0.51 builds that path (poll-by-id), and its exposure is a trust-tier
  decision, recorded here.

## Decision

### Inbound trust posture
- An external client reaching any public surface is an **untrusted inbound
  tier**. It never receives more authority than a local workspace user.
- Metadata, protocol fields, transport identity, and client-supplied permission
  responses **never grant authority** (ADR 0038 applied inbound). Specifically,
  the ACP `session/request_permission` response is advisory only and never
  authorizes execution.
- Protocol payload shape is metadata, not authority. OpenAI/ACP image, audio,
  file, embedded-resource, filesystem-root, and client-supplied MCP-server
  fields are rejected or recorded as bounded metadata unless a later ADR/plan
  adds an explicit capability-specific route.
- Every effectful call routes through `Actions.Runner.run/3`, Security Central,
  Resource Access, confirmations, traces, and audits — the same path as a local
  workspace user.

### Permission class
- New permission class **`:public_surface_call_inbound`**, safety floor
  **`:needs_confirmation`**, registered at every spot the `:artifact_*` precedent
  touches: `Security.Policy` `@permission_settings`, `@default_decisions`, the
  `permission()` type, `permission_classes/0`, a `safety_floor/2` clause, and the
  `reason/5` trace/status clauses; `Security.Risk` `tier/1` + `reasons/3`; and
  `Settings.Schema` `@safe_write_keys` + the permission `defaults` enum.
- `Security.Risk.classify/2` receives a tier and reasons for
  `:public_surface_call_inbound` so Security Central status, operator displays,
  and tests explain why inbound public clients are high-risk even when a surface
  is local/private.
- Confirmation-decision actions (`approve_confirmation`/`deny_confirmation`)
  remain `exposure: :internal` and are never exposable — this is the
  self-approval-denial enforcement point. External clients cannot approve their
  own confirmations.

### Settings Central contract
- M1 adds ADR 0046 schema-versioned safe-write fragments:
  `mcp_server.*`, `openai_api.*`, `acp_server.*`, and shared
  `public_protocol.*`, all default-off and default-empty except bounded shared
  defaults such as readback TTL and max body bytes. Unknown keys are rejected.
- HTTP client entries use Settings Secrets token refs, enabled flags, and
  per-client/per-surface rate-limit settings. Secret refs may be audited; raw
  bearer tokens never appear in settings output, CLI output, traces, audits, or
  tests.
- Settings validation rejects invalid client ids, invalid port/rate-limit ranges,
  non-local bind hosts unless a later hardening plan enables them, allowlisted
  tools that fail the public exposure deny rules, memory namespaces outside app
  namespaces, and model aliases that do not resolve to configured profiles.
- `permissions.public_surface_call_inbound` defaults to `needs_confirmation` and
  cannot be lowered below the safety floor.

### Per-client authentication (HTTP-bearing surfaces)
- MCP streamable-HTTP and the OpenAI-compatible API require a **per-client token
  issued through Settings Central**, stored in Settings Secrets (encrypted at
  rest), never logged, and compared with `Plug.Crypto.secure_compare` (the
  `Voice.LocalRuntime.Auth` pattern, generalized to Settings-Secrets issuance).
  Tokens are operator-issued, rotatable, and revocable; an absent/invalid/revoked
  token is rejected before any runtime work.
- Token issuance uses the operator CLI
  `mix allbert.public_protocol token create|rotate|revoke|list --surface <mcp_http|openai_api> --client <id>`.
  `create` and `rotate` print the new raw bearer token once; every other command,
  trace, audit, and test evidence path redacts it.
- This is an Allbert local/private ingress-auth subset, not an MCP OAuth 2.1
  protected-resource / authorization-server implementation. Remote/public OAuth
  parity is future work and is not v0.51 acceptance.
- Reusable bearer tokens do **not** provide replay prevention by themselves. This
  ADR requires token redaction, revocation denial, and rate-limit-before-runtime
  behavior. If v0.51 later claims replay denial, M4 must add and test an
  explicit nonce, request-signature, token-binding, or idempotency mechanism.
- stdio surfaces (MCP stdio + ACP) run under ADR 0009 process bounds; their trust
  derives from the local process boundary, not a token.

### Inbound rate-limiting
- A net-new per-client/per-surface inbound rate limiter (a supervised
  token-bucket; no existing limiter to reuse) applies uniformly to HTTP-bearing
  surfaces. Exceeding the limit is rejected before runtime work and audited.
- HTTP ingress enforces request body limits before expensive parsing/runtime
  work where the transport allows it. Authentication and rate limiting both run
  before `Runtime.submit_user_input/1` or `Actions.Runner.run/3`.

### API secure-header posture
- JSON API responses (MCP streamable-HTTP + OpenAI API) use an
  **API-appropriate secure-header policy** (`default-src 'none'`,
  `frame-ancestors 'none'`, no inline/eval), **distinct from the ADR 0025 §3
  browser CSP baseline** (which is a browser-response defense and a category
  mismatch for JSON APIs). This reconciles the ADR 0025 note that the CSP
  baseline must be revisited for external surfaces.

### Result readback (poll-by-id)
- The ownership record is an **Ecto-backed public protocol readback table** in
  the Allbert Assist DB, not an Allbert Home flat file and not additional raw
  confirmation-store metadata.
- A new **read-only, `:agent`-exposable** action (e.g. `get_public_call_result`)
  lets a client retrieve a confirmation/call result **by id**. It returns one of
  `pending | approved_with_result | denied | expired`.
- The readback is **client-scoped**: a client may read only confirmations/calls
  it originated; it never sees other clients' results (no cross-client leak).
- It **never returns a result before the operator has approved** the underlying
  confirmation; before approval it returns `pending` only.
- It exposes the action *result* (already redacted by `Runtime.Redactor`), not
  confirmation-store internals.
- The ownership record stores only public call id, surface, client id,
  action/turn label, confirmation id when present, trace id,
  created/resolved/expires timestamps, status, and redacted result/error
  metadata. It does not expose `show_confirmation`, `list_confirmations`, raw
  confirmation payloads, trace bodies, or secrets.
- Entries expire after the configured TTL. Expired entries return an
  `expired`/protocol-shaped equivalent with no result bytes and leave audit
  evidence of expiry.

### HTTP transport posture
- MCP streamable HTTP and OpenAI-compatible JSON responses use the API secure
  headers decided above. MCP HTTP additionally validates Origin for browser-
  reachable requests, defaults local deployments to localhost binding, documents
  `Mcp-Session-Id` behavior, validates `MCP-Protocol-Version` when present, and
  either implements DELETE session termination or returns an explicit 405.
  v0.51 targets the pinned Hermes-supported MCP versions (`2025-03-26` /
  `2025-06-18` where available); unsupported newer versions such as
  unverified `2025-11-25` are rejected before runtime work.
- MCP stdio and ACP stdio keep stdout protocol-clean and send logs to stderr.

## Consequences
- The inbound boundary gets the same named-permission + safety-floor rigor as
  every other capability boundary, and a documented auth/rate-limit/secure-header
  posture rather than scattered plan prose.
- v0.51 must build genuinely new substrate (Settings-Secrets per-client tokens, a
  token-auth plug, an inbound rate-limiter, and the poll-by-id readback) — these
  are not "thin adapters." The plan budgets milestones for them.
- The v0.57 security eval sweep covers this tier: self-approval denial, token
  redaction/revocation, rate-limit-before-runtime, client-scoped readback,
  no-result-before-approval, readback expiry, cross-client confusion,
  unsupported media/resource payload denial, and metadata-never-authority (ACP).
- ADR 0038 stays scoped to the outbound client tier; the inbound/outbound trust
  boundary stays clean.

## Related
- ADR 0044 (public protocol exposure — which surfaces, what's exposed).
- ADR 0038 (outbound MCP client trust tier — the symmetric pattern).
- ADR 0006 (Security Central), ADR 0009 (process/sandbox bounds), ADR 0025
  (browser CSP baseline — reconciled here for APIs), ADR 0046 (settings schema
  migration for the `*_server`/`*_api` fragments).
- `docs/plans/v0.51-plan.md`, `docs/plans/v0.51-request-flow.md`.
