# ADR 0056: Channel Inbound Trust Tier

## Status

Accepted at v0.52 M8 closeout for Channel Pack 1 - Discord And Slack
(`docs/plans/v0.52-plan.md`).

Accepted amendment (v0.53, public signed-webhook inbound): v0.52 channels were
outbound-initiated (Discord Gateway, Slack Socket Mode) with no public URL. v0.53
WhatsApp Cloud API (and the deferred Viber twin) are **public HTTPS webhook**
channels: the provider POSTs inbound events to a publicly reachable endpoint. The
inbound trust tier extends to that shape — Allbert verifies the provider's
**raw-body HMAC signature before parsing** (WhatsApp `X-Hub-Signature-256` keyed
by the app secret, computed with `:crypto.mac(:hmac, :sha256, ...)`; Viber
`X-Viber-Content-Signature` keyed by the auth token), with
`Plug.Crypto.secure_compare/2`. It **reuses** the v0.51 ingress's rate-limiter
(keyed on the provider install bucket), secure-header posture, body cap, and
router pipeline rather than a second ingress — but the verification itself is
**net-new**: v0.51's body reader does not retain the raw body (it streams and
discards), and v0.51's auth is bearer-token-based, so v0.53 adds raw-body
preservation (cache before `Plug.Parsers`) and a **signature-auth plug distinct
from the bearer-token auth**. An absent/invalid signature is rejected before any
parsing or runtime work; the registration/verification handshake (WhatsApp
`hub.challenge`) is answered without granting authority. Self-hosted operators without a public
URL use a tunnel; the signed webhook is the only inbound path for these channels.
`:channel_message_inbound` and all v0.52 invariants apply unchanged. This
amendment was accepted at v0.53 M10 implementation closeout; live provider smoke
validation remains the pre-tag release gate. See `docs/plans/v0.53-plan.md`.

Operator validation of this signature path (v0.53 closeout): the signature/verify-token
contract is exercised **locally without a tunnel** by `mix allbert.channels whatsapp
post-webhook` — it computes the same `sha256=`-prefixed HMAC over the exact raw body
and issues a real HTTP POST to `/webhooks/whatsapp/{phone_number_id}` on a running
endpoint (loopback admitted because the request carries no `Origin` header), and
`--bad-signature` confirms the `:invalid_webhook_signature` → HTTP 401 denial before
any parse. This is deliberately **distinct from `mix allbert.channels whatsapp
simulate`**, which injects the parsed event in-process (`:stub` mode) and therefore
**bypasses the HTTP ingress and this trust tier**: `simulate` validates
parsing/identity/routing only and must not be read as evidence for the signature
boundary. The deterministic guarantees stay covered by the `:v053` eval rows
`whatsapp-webhook-signature-verify-before-parse-001` and
`whatsapp-webhook-bad-signature-deny-001`.

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
- Provider reply/thread metadata (Slack `thread_ts`, Slack message `ts`,
  Discord thread-channel ids, Discord `message_reference`) may scope channel
  session continuity and outbound reply placement, but it is never Allbert
  conversation `thread_id` authority and never grants permission.
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
  submission. The message path and the interactive/callback path apply the
  **same allowlist predicate** (team/guild + channel) so an unmapped surface
  cannot reach the runtime through either entry (clarified v0.52 M8R6/M8R7;
  Slack `validate_allowlist`/`validate_callback_allowlist`, Discord guild/channel
  predicates unified).
- **Identity must be mapped.** An inbound event without a `Channels.Identity`
  entry produces a rejected-unknown `channel_events` record and no submission;
  there is no implicit `user_id`.
- **DM inbound is gated by the identity map, not a channel allowlist.** A direct
  message carries no guild/team-channel id an operator can pre-list (Slack DMs
  use an ephemeral `D…` id; a Discord DM has no `guild_id`). The identity map is
  therefore the DM authorization gate: only a mapped external sender resolves to
  a local user and passes, while the channel-id allowlist applies to
  team/guild channels only (the DM bypasses it but remains team/workspace
  scoped). This is the identity-map-is-the-DM-allowlist posture — no separate DM
  allowlist setting is introduced, because the identity map already names exactly
  the senders allowed to DM the bot. Slack DM admission additionally honors
  `channels.slack.response_style` (`mention`/`always`/`dm_only`); `dm_only`
  serves DMs only, and provider echoes (`bot_id`/`subtype`/own bot user id) are
  dropped before any `channel_events` write (v0.52 M8R6).
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
