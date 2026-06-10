# ADR 0056: Channel Inbound Trust Tier

## Status

Proposed for v0.52 Channel Pack 1 — Discord And Slack
(`docs/plans/v0.52-plan.md`). Flips to Accepted at v0.52 M5.

This ADR is the **channel** counterpart to ADR 0055 (the public-surface inbound
trust tier) and ADR 0038 (the outbound MCP client trust tier). ADR 0016 decides
the channel **boundary** — which adapters exist, how external identity maps to a
local user, and how approval primitives render. This ADR decides **how Allbert
trusts the external senders that reach a channel** — the inbound permission
class, its safety floor, and the per-message authentication/authorization
invariants that gate the boundary.

## Context

v0.52 adds Discord and Slack channel adapters (ADR 0016). An external sender in a
Discord guild or a Slack workspace is an **untrusted inbound caller** in exactly
the sense ADR 0055 named for public-protocol clients and ADR 0038 named for
outbound MCP servers: their metadata, protocol fields, and interactive-component
payloads are never authority.

Until v0.52, channels relied on the ADR 0016 posture — identity mapping plus an
operator allowlist — as the trust boundary, without a named permission class.
v0.51 established the convention that an untrusted inbound surface gets a **named
permission class with a safety floor**, introduced by an ADR and landed in
`Security.Policy.permission_classes/0` (ADR 0055 for public surfaces, ADR 0042
for voice, ADR 0053 for artifacts). Channel inbound must follow the same pattern
rather than living as plan prose, so the inbound boundary is explainable in
Security Central status and enforceable in tests symmetrically with every other
inbound tier.

Channel inbound is untrusted **yet distinct** from public-surface inbound:

- A channel message only reaches the runtime after it resolves to an
  **allowlisted, identity-mapped local operator** (`Channels.Identity`). A
  public-surface client is an anonymous bearer of a Settings-Central token. So
  the channel tier authenticates *to a known local user and inherits that user's
  authority*, while still treating the message content, sender-supplied fields,
  and component payloads as untrusted input.
- The authentication primitive is the identity map + allowlist (ADR 0016), not a
  per-client token. The new permission class records the **trust tier and floor**
  of the resolved inbound call; it does not replace identity mapping.

## Decision

### Inbound trust posture
- An external sender reaching any channel adapter is an **untrusted inbound
  tier**. A resolved inbound call never receives more authority than the
  local workspace user it maps to.
- Sender metadata, message fields, callback/component payloads
  (Discord `custom_id`, Slack `action_id`/`value`), `cwd`-equivalent client
  hints, and interactive-component identity claims **never grant authority**.
- Every effectful call routes through `Actions.Runner.run/3`, Security Central,
  Resource Access, confirmations, traces, and audits — the same path as a local
  workspace user.

### Permission class
- New permission class **`:channel_message_inbound`**, safety floor
  **`:needs_confirmation`**, registered at every spot the `:artifact_*` /
  `:public_surface_call_inbound` precedent touches: `Security.Policy`
  `@permission_settings`, `@default_decisions`, the `permission()` type,
  `permission_classes/0`, a `safety_floor/2` clause, and the `reason/5`
  trace/status clauses; `Security.Risk` `tier/1` + `reasons/3`; and
  `Settings.Schema` `@safe_write_keys` + the permission `defaults` enum.
  Omitting `@permission_settings`, `reason/5`, or the `Settings.Schema` entries
  half-wires the class and fails the settings/trace-reason tests.
- The configured decision defaults to `needs_confirmation` and **cannot be
  lowered below the safety floor**.
- Confirmation-decision actions (`approve_confirmation`/`deny_confirmation`)
  remain `exposure: :internal` and are never reachable through a channel — this
  is the self-approval-denial point.

### Authentication and authorization invariants
- **Allowlist before runtime.** Discord guild + channel allowlists and the Slack
  channel allowlist gate inbound handling before `Runtime.submit_user_input/1`.
  Non-allowlisted surfaces produce a rejected `channel_events` record and no
  submission.
- **Identity must be mapped.** An inbound event without a `Channels.Identity`
  entry produces a rejected-unknown `channel_events` record and no submission;
  there is no implicit `user_id`.
- **Clicker re-authorized per interaction.** A button/component tap re-resolves
  the **clicker's** external id through the identity map on every tap; the
  callback payload's embedded user fields are never trusted as authority. An
  unmapped/unauthorized clicker is rejected (ephemeral "not authorized") and
  recorded as a rejected `channel_events` row. The confirmation action also
  enforces that the resolved clicker owns the open pending request.
- **Ack before runtime.** The provider acknowledgement (Slack envelope ack /
  Discord deferred component response) precedes the slow runtime submission;
  `channel_events` dedupe absorbs Slack retries and Discord RESUME redelivery so
  no message double-submits and no confirmation double-approves.
- **Cross-channel isolation.** A pending confirmation records its origin
  channel/surface; a callback from a different provider cannot resolve it.
- **Secrets.** Bot/app tokens and signing secrets are `secret://` references,
  encrypted at rest, never in `channel_events`, traces, audits, settings output,
  or tests.

## Consequences
- The channel inbound boundary gets the same named-permission + safety-floor
  rigor as every other inbound tier, and is explainable in Security Central
  status rather than implicit in adapter code.
- v0.52 M0 registers `:channel_message_inbound` at all spots above; the v0.52
  eval set covers the tier (permission/floor, clicker authorization,
  cross-channel isolation, allowlist/identity gating, secret redaction).
- ADR 0016 stays the channel boundary + approval-primitive umbrella; ADR 0055
  stays the public-surface inbound tier; the inbound trust boundaries stay clean
  and symmetric.

## Related
- ADR 0016 (channel adapter boundary, identity mapping, approval primitives).
- ADR 0055 (public-surface inbound trust tier — the symmetric pattern).
- ADR 0038 (outbound MCP client trust tier).
- ADR 0006 (Security Central), ADR 0014 (local identity), ADR 0031 (settings
  fragments), ADR 0049 (development lanes).
- `docs/plans/v0.52-plan.md`, `docs/plans/v0.52-request-flow.md`.
