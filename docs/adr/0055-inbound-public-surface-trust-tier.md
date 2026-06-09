# ADR 0055: Inbound Public-Surface Trust Tier

## Status

Proposed for v0.51 Public Protocol Surfaces (`docs/plans/v0.51-plan.md`). Flips to
Accepted at v0.51 M1.

This ADR is the **inbound** counterpart to ADR 0038 (the outbound MCP *client*
trust tier). ADR 0044 decides *which* public surfaces ship and *what* they
expose; this ADR decides *how Allbert trusts the external clients that reach
those surfaces* — the inbound permission class, per-client authentication,
rate-limiting, the API secure-header posture, and the result-readback exposure.

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
- Every effectful call routes through `Actions.Runner.run/3`, Security Central,
  Resource Access, confirmations, traces, and audits — the same path as a local
  workspace user.

### Permission class
- New permission class **`:public_surface_call_inbound`**, safety floor
  **`:needs_confirmation`**, registered in `Security.Policy.permission_classes/0`,
  `@default_decisions`, the `permission()` type, and a `safety_floor/2` clause.
- Confirmation-decision actions (`approve_confirmation`/`deny_confirmation`)
  remain `exposure: :internal` and are never exposable — this is the
  self-approval-denial enforcement point. External clients cannot approve their
  own confirmations.

### Per-client authentication (HTTP-bearing surfaces)
- MCP streamable-HTTP and the OpenAI-compatible API require a **per-client token
  issued through Settings Central**, stored in Settings Secrets (encrypted at
  rest), never logged, and compared with `Plug.Crypto.secure_compare` (the
  `Voice.LocalRuntime.Auth` pattern, generalized to Settings-Secrets issuance).
  Tokens are operator-issued, rotatable, and revocable; an absent/invalid/revoked
  token is rejected before any runtime work.
- stdio surfaces (MCP stdio + ACP) run under ADR 0009 process bounds; their trust
  derives from the local process boundary, not a token.

### Inbound rate-limiting
- A net-new per-client/per-surface inbound rate limiter (a supervised
  token-bucket; no existing limiter to reuse) applies uniformly to HTTP-bearing
  surfaces. Exceeding the limit is rejected before runtime work and audited.

### API secure-header posture
- JSON API responses (MCP streamable-HTTP + OpenAI API) use an
  **API-appropriate secure-header policy** (`default-src 'none'`,
  `frame-ancestors 'none'`, no inline/eval), **distinct from the ADR 0025 §3
  browser CSP baseline** (which is a browser-response defense and a category
  mismatch for JSON APIs). This reconciles the ADR 0025 note that the CSP
  baseline must be revisited for external surfaces.

### Result readback (poll-by-id)
- A new **read-only, `:agent`-exposable** action (e.g. `get_public_call_result`)
  lets a client retrieve a confirmation/call result **by id**. It returns one of
  `pending | approved-with-result | denied`.
- The readback is **client-scoped**: a client may read only confirmations/calls
  it originated; it never sees other clients' results (no cross-client leak).
- It **never returns a result before the operator has approved** the underlying
  confirmation; before approval it returns `pending` only.
- It exposes the action *result* (already redacted by `Runtime.Redactor`), not
  confirmation-store internals.

## Consequences
- The inbound boundary gets the same named-permission + safety-floor rigor as
  every other capability boundary, and a documented auth/rate-limit/secure-header
  posture rather than scattered plan prose.
- v0.51 must build genuinely new substrate (Settings-Secrets per-client tokens, a
  token-auth plug, an inbound rate-limiter, and the poll-by-id readback) — these
  are not "thin adapters." The plan budgets milestones for them.
- The v0.57 security eval sweep covers this tier: self-approval denial, token
  replay/revocation, rate-limit, client-scoped readback, no-result-before-
  approval, cross-client confusion, and metadata-never-authority (ACP).
- ADR 0038 stays scoped to the outbound client tier; the inbound/outbound trust
  boundary stays clean.

## Related
- ADR 0044 (public protocol exposure — which surfaces, what's exposed).
- ADR 0038 (outbound MCP client trust tier — the symmetric pattern).
- ADR 0006 (Security Central), ADR 0009 (process/sandbox bounds), ADR 0025
  (browser CSP baseline — reconciled here for APIs), ADR 0046 (settings schema
  migration for the `*_server`/`*_api` fragments).
- `docs/plans/v0.51-plan.md`, `docs/plans/v0.51-request-flow.md`.
