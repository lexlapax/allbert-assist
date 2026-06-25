# ADR 0073: Cross-Surface Contract

Status: Proposed (v0.58); M13 implemented, M13.1A-F complete; ready for the
fourth-pass implementation audit, then M14 manual validation if no blocker remains.
Date: 2026-06-24
Related: ADR 0016 (channel adapter boundary + identity mapping — extended here to
every surface), ADR 0029/0030 (typed response contract + unified surface
renderer — the single render path this contract requires), ADR 0070 (operator
read-only actions — the operator-read discipline extended to the web), ADR 0006
(Security Central — unchanged authority), ADR 0004/0031 (Settings Central — the
only config authority), ADR 0057 (cross-channel threading — thread mapping stays
that ADR's concern). Anchors the v0.58 surface-consistency pillar.
Rationale source: the v0.58 rescope surface survey (2026-06-24).

## Context

Allbert is driven through many **surfaces**: the web LiveView workspace, the
TUI/terminal channel, seven messaging channel adapters (Telegram, Discord, Slack,
Matrix, WhatsApp, Signal, email), Mix tasks, the public-protocol servers (MCP
server, ACP, OpenAI-compatible API), and the v0.57 Pi-mode coding surface.

ADR 0016 defines a clean methodology for **channel** surfaces: normalize inbound
input → resolve identity through the list-shaped identity map → derive a
channel-scoped session → `Runtime.submit_user_input/1` → render the typed
response → record the inbound event with dedupe + trace. The eight channel
surfaces (seven messaging + TUI) follow this uniformly.

The v0.58 rescope survey found that the **non-channel surfaces do not**:

- **Web workspace** reads `Confirmations` storage directly, reads `Settings.Store`
  directly, hardcodes `user_id: "local"` (no `Identity.resolve`), can invoke any
  action (no operator-read discipline), records no inbound/error event, and has
  its own bespoke response rendering.
- **Mix tasks** use a `LocalSurface` abstraction instead of the shared session
  derivation, record no events, and each re-implements `context/0`,
  `completed_action/2`, and `response_error/1`.
- **Public-protocol servers** invoke actions but do not record events and format
  responses independently.

The result is five distinct response renderers, an audit/event gap on three
surfaces, surface-local config and confirmation reads, and ~20× duplicated
invocation boilerplate. Before the v1.0 freeze, every surface must follow **one**
contract so the platform is consistent, auditable, and freezable.

## Decision

Adopt a single **Cross-Surface Contract**. Every surface — channel and
non-channel alike — is a **thin, uniform view over the one runtime/action/settings
spine**. A surface adapts transport and presentation; it owns no authority, no
config, no business logic, and no bespoke read path.

A conformant surface MUST:

1. **Normalize → resolve identity → derive session.** Inbound input is normalized,
   the actor is resolved through `Channels.Identity.resolve` against the
   list-shaped identity map (no hardcoded `"local"`), and a session id is derived
   through the shared seam. Non-channel surfaces use a stable `surface_id`
   (`live_view`, `cli`, `mcp_stdio`, `mcp_http`, `acp`, `openai_api`) in place of
   a provider channel id.
2. **Invoke through the spine only.** User turns go through
   `Runtime.submit_user_input/1`; direct operations go through
   `Actions.Runner.run/3`. No surface calls business logic, `Confirmations`
   storage, or `Settings.Store` directly.
3. **Render through the one renderer.** Surfaces render the typed
   `Runtime.Response` (`model_payload` / `surface_payload`) through the single
   `Surface.Renderer` against a surface descriptor (render primitives — the
   `[:typed_command, :list, :button, :link]` set defined by ADR 0016). The
   five bespoke renderers are collapsed into this one path; `model_payload` never
   leaks `surface_payload` chrome, and only `model_payload` threads into memory.
4. **Record events + trace uniformly.** Every surface records inbound, rejection,
   and error events to the shared channel-event spine keyed by `surface_id`, with
   dedupe and trace, so the audit trail is identical across surfaces. This includes
   protocol rejections that happen before runtime dispatch, such as invalid ACP
   guard/session/permission/unsupported-method requests and MCP resource/tool
   exposure denials.
5. **Read operator state through registered actions.** Operator reads
   (confirmations, settings, channels, intents, models, status) resolve through
   the ADR 0070 read-only action layer (`exposure: :internal`,
   `permission: :read_only`), not direct store reads — on the web exactly as on
   the TUI and Mix.
6. **Build context through the shared builder.** Surfaces build the
   `Actions.Runner` context through a shared `Surfaces.ContextBuilder` and invoke
   through a shared `Actions.Helper`, rather than re-implementing `context/0` /
   `completed_action/2` / `response_error/1`.

A **conformance matrix** (surface × requirement 1–6) is maintained in the v0.58
plan. M13 implemented the main spine. M13.1 closes the remaining audit partials
before M14. M13.1A closed residual web settings reads plus ACP prompt-guard and
MCP `read_resource` rejection recording; M13.1E extended rejection recording to
ACP sibling methods and MCP tool exposure denials; M13.1C closed explicit
surface-policy report-shape coverage for the named operator-panel reads.

## v0.58 M13.1 Conformance Notes

The pass-1 implementation audit found no new authority grant, but it did find
edge drift that must be remediated before this ADR can be accepted:

- Complete in M13.1A: provider/model profile DTOs are redacted at source. A
  rendered template that omits endpoint URLs or secret refs is not enough; the
  DTO handed to web, TUI, CLI, or assistant-safe contexts must not carry those
  fields.
- `list_provider_profiles` and `list_model_profiles` may remain assistant-safe
  `:agent` reads only under the ADR 0070 carve-out: source-redacted DTOs, bounded
  reports, and no raw operator fields in the agent-routable packet.
- Complete in M13.1A/E: public-protocol pre-dispatch rejections record the same
  rejection/error event shape as dispatched runtime failures. M13.1A covers ACP
  prompt guard `else` returns and MCP resource-read denials; M13.1E extends the
  proof to ACP session, permission, unsupported-method failures and MCP
  `tool_not_exposed` denials.
- Complete in M13.1C: surface policy is presentation governance, not authority.
  It now governs `list_settings`, `list_channels`, `list_model_profiles`,
  `list_provider_profiles`, `intent_coverage`, `intent_list_descriptors`,
  `intent_list_review`, and `model_doctor`. The added reads remain internal and
  non-routable; raw operator reports require an explicit surface affordance.

## Non-goals and guardrails

- **No authority change.** Security Central remains the only authority; this
  contract is about *how surfaces reach the spine*, not what they may do. Operator
  reads stay `:internal`/non-routable; web panels gain no new authority.
- **Threading stays ADR 0057.** Provider-thread mapping heterogeneity is the
  cross-channel threading concern; non-provider surfaces mark it N/A.
- **Intentional async asymmetry kept.** The Pi-mode supervised coding-turn
  boundary (ADR 0068) is surface-specific and is not forced onto non-coding
  surfaces.
- **Settings stay in Settings Central.** No surface reads operator-tunable config
  outside Settings Central (see the ADR 0004/0031 v0.58 enforcement note).

## Consequences

- One response renderer, one event/audit path, one identity/session seam, and one
  invocation helper across every surface; the web stops reading confirmations and
  settings directly.
- The operator-read action layer (ADR 0070) becomes the single operator-read path
  on every surface, making web/TUI/CLI/MCP return the same redacted DTOs.
- The conformance matrix is the standing check; v0.59 inherits a uniform base for
  param-contract enforcement (ADR 0065) and the final security/cleanup sweep.
- v1.0 freezes this contract as part of the surface/channel boundary.
