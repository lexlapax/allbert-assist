# ADR 0059: Channel Trust-Class And Cross-Surface Relay Gating

## Status

Accepted at v0.53 M10 implementation closeout for Channel Pack 2 + system-wide
constructs (`docs/plans/v0.53-plan.md`). Live provider smoke validation remains
the pre-tag release gate.

This ADR **completes a promise ADR 0057 made but did not build**: that
"E2EE-origin content is never relayed without explicit operator action." v0.52
shipped the cross-channel threading substrate (`thread_channel_refs`,
`conversation_message_refs`, the unified history view, and
`resume_thread_on_channel`) but with **no trust/encryption metadata** — the
unified view aggregates every channel uniformly and resume relays content with no
origin check. v0.53 adds the channels (Signal always-E2EE; WhatsApp Cloud API
server-readable; Matrix unencrypted rooms) that make this gap real.

## Context

The v0.52 substrate verification confirmed: there is no `trust_class` /
`encryption_origin` column on any ADR 0057 table, and
`Conversations.UnifiedHistory.show_thread/3` and `resume_thread_on_channel/1`
have no origin gating. v0.53 introduces channels with materially different
content-trust properties:

- **Signal** is always end-to-end encrypted; plaintext exists only at the
  `signal-cli` daemon (ADR 0058). Content arriving from Signal originated inside
  an E2EE envelope.
- **WhatsApp Cloud API** is *not* client-E2EE to Allbert — Meta decrypts and
  Allbert receives plaintext over the webhook. **Viber and Telegram bots** are
  the same class (transport-encrypted, server-readable).
- **Matrix** unencrypted rooms are plain; encrypted Matrix rooms are out of scope
  for v0.53 (no Elixir E2EE support).
- **Web / CLI** are local surfaces Allbert fully controls.

Mature bridges (mautrix) terminate remote E2EE at the bridge — content leaves the
E2EE envelope the moment it is bridged. Allbert is in the same position the
instant it aggregates Signal content into the unified view or resumes it on a
non-E2EE channel. v0.52's stated guarantee therefore needs real machinery, not
prose.

## Decision

### Trust-class taxonomy
Every channel message and thread mapping carries a **`trust_class`**:

- **`:e2ee_origin`** — content originated inside an end-to-end-encrypted envelope
  that Allbert (or its supervised daemon) terminated: Signal; a future
  whatsapp-web bridge; encrypted Matrix rooms (if ever supported).
- **`:server_readable`** — transport-encrypted but readable by a third-party
  server in transit: WhatsApp Cloud API, Viber, Telegram bots, Slack, Discord,
  email.
- **`:local`** — surfaces Allbert controls: web, CLI.

The class is a property of the **inbound channel**, declared on the channel
descriptor (`trust_class:`) and stamped onto the mapping rows; it is metadata and
never grants authority.

### Substrate field
- `thread_channel_refs` and `conversation_message_refs` gain a `trust_class`
  column (default `:server_readable` for existing v0.52 rows;
  backfill is a no-op for Discord/Slack which are `:server_readable`).
- `Conversations.ChannelThread` stamps `trust_class` from the channel descriptor
  when recording refs.

### Gating (the v0.52 promise, now enforced)
- **Unified history view** (`UnifiedHistory.show_thread/3`): by default it does
  **not** include `:e2ee_origin` content from a *different* channel in the
  aggregated cross-channel view. The operator can opt in per request/setting
  (`include_e2ee_origin: true`), which is audited. Within the originating E2EE
  channel's own view, content shows normally.
- **`resume_thread_on_channel`**: relaying a canonical thread whose content
  includes `:e2ee_origin` messages onto a channel of a *weaker* class
  (`:server_readable`) requires an **explicit operator confirmation** that names
  the downgrade (e.g. "this resumes Signal (E2EE) content onto WhatsApp
  (server-readable)"). Resuming onto `:local` or same-or-stronger class proceeds
  normally. There is no silent live mirroring (ADR 0057 restated).
- These gates are **operator-facing, not a hard prohibition**: the construct
  makes the cross-surface exposure of E2EE-origin content a deliberate,
  audited choice rather than an accident — matching how bridges actually behave
  while honoring the v0.52 guarantee.

### Honest framing
- Once an operator opts in or confirms a downgrade, the content has genuinely left
  its E2EE envelope and lives in Allbert's plaintext substrate and any target
  channel. The docs state this plainly; the construct controls *exposure
  decisions*, not cryptographic guarantees Allbert cannot make after termination.

## Consequences
- The unified view and resume gain a real, audited trust boundary; ADR 0057's
  E2EE-origin promise is implemented rather than aspirational.
- v0.53 retrofits the web and CLI unified-view surfaces to honor `trust_class`
  (a "modify existing channels" milestone).
- The v0.53 eval set covers: `:e2ee_origin` content excluded from the default
  cross-channel view, opt-in audited, resume-downgrade confirmation required and
  audited, `trust_class` stamped correctly per channel, and trust metadata never
  granting authority.

## Related
- ADR 0057 (cross-channel threading — the substrate this completes).
- ADR 0058 (key custody — Signal's E2EE keys live in the supervised daemon).
- ADR 0016 (channel boundary), ADR 0056 (channel inbound trust tier), ADR 0006
  (Security Central), ADR 0049 (development lanes).
- `docs/plans/v0.53-plan.md`, `docs/plans/v0.53-request-flow.md`.
