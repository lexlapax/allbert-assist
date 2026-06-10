# ADR 0057: Cross-Channel Conversation Threading And Relay

## Status

Accepted at the v0.52 closeout milestone for Channel Pack 1 +
Cross-Channel Conversation Threading (`docs/plans/v0.52-plan.md`).

This ADR adds a **system-wide conversation-thread construct** that spans every
channel. ADR 0016 owns the channel boundary + approval primitives; ADR 0056 owns
the inbound trust tier; this ADR owns **how one canonical Allbert conversation
maps to, and is rendered into, each channel's native (or absent) threading
model** — the mapping tables, the per-adapter threading capability, the
degradation ladder, echo-loop suppression, explicit cross-channel identity
links, the unified history view, and the explicit resume action.

## Context

Allbert already has the durable conversation substrate: `conversation_threads`
(per-`user_id`, id `thr_<UUID>`) and `conversation_messages`, with
`Conversations.resolve_thread/1` as the single thread authority called inside
`Runtime.submit_user_input/1`. Channels today derive only a `session_id`
(`Channels.derive_session_id/3`); they never set `thread_id`. There is **no**
cross-channel relay, no provider-thread mapping table, and no unified view.

v0.52 adds Discord and Slack and, with them, the question the v0.52 readiness
sweep deferred: how does one Allbert conversation stay coherent across channels
with **wildly different threading models** — Slack `thread_ts`, Discord
threads-are-channels + `message_reference`, Telegram forum topics vs. flat DMs,
email `Message-ID`/`In-Reply-To`/`References`, SMS (no threading at all),
WhatsApp/Signal quotes (reply-by-id / reply-by-timestamp), Matrix `m.thread` —
versus web/CLI, which Allbert fully controls.

Research into Matrix bridges (`mautrix` bridgev2 `Portal`/`Message` model) and
matterbridge yields a reusable pattern: a canonical conversation id, a durable
per-channel mapping table, a durable per-message mapping table (for reply
translation, dedup, and echo suppression), and a per-adapter capability
declaration that drives reply/thread rendering with a degradation ladder. The
strong cross-cutting lesson is that **silent auto-merging of one live
conversation across channels is unsafe** (it re-exposes content that arrived on
a channel with different trust/encryption, and multiplies echo/ordering
hazards). The safe shape is **continuity within each channel + a unified
read-only history view + an explicit operator "resume here" action**.

## Decision

### Canonical thread = the existing thread id
- The canonical conversation id **is** `conversation_threads.id` (`thr_<UUID>`).
  No new id is introduced. `Conversations.resolve_thread/1` remains the sole
  thread authority. Provider thread/reply metadata is **never** `thread_id`
  authority and never grants permission (ADR 0056 restated).

### Durable mapping tables
- **`thread_channel_refs`**: `owner_scope`, `canonical_thread_id`, `channel`,
  `receiver_account_ref`, `provider_thread_key`, `provider_thread_ref`, and
  timestamps. Unique key:
  `UNIQUE(owner_scope, channel, receiver_account_ref, provider_thread_key)`.
  Records where a canonical thread lives on each channel (Slack
  `{team_id, channel_id, thread_ts}`; Discord
  `{guild_or_dm_id, channel_or_thread_id}`; Telegram
  `{bot_id, chat_id, message_thread_id?}`; email
  `{mailbox_id, root_message_id, references[]}`; flat channels `{peer}`).
- **`conversation_message_refs`**: `owner_scope`, `canonical_message_id`,
  `canonical_thread_id`, `channel`, `receiver_account_ref`,
  `provider_message_id`, `part_id`, `direction`, and timestamps. Unique key:
  `UNIQUE(owner_scope, channel, receiver_account_ref, provider_message_id,
  part_id)`. Powers reply/thread translation, dedup, and
  **echo-loop suppression**. `part_id` because one canonical message may split
  into N native messages (length/attachment limits). `direction` (`in`/`out`)
  is load-bearing: an inbound event whose `provider_message_id` matches a
  recorded `out` ref is Allbert's own echo and is dropped.
- **`cross_channel_identity_links`**: `owner_scope`, `link_id`, `user_id`,
  `channel`, `receiver_account_ref`, `external_user_id`, and timestamps.
  Unique key:
  `UNIQUE(owner_scope, link_id, channel, receiver_account_ref,
  external_user_id)`. Links group already-authenticated channel identities for
  unified history and explicit resume; they never authenticate by themselves.
- These tables are durable SQLite (never in-memory caches — the matterbridge
  failure mode where threading is lost on restart).

### Tenant-safe owner/account/key scope
- `owner_scope` is a required string on every ADR 0057 table. v0.52 uses the
  constant `"local"` because Allbert is still local-first and single-operator.
  The field is a schema hook for post-1.0 multi-user/multi-tenant ownership; it
  grants no authority and does not introduce hosted tenancy in v0.52.
- `receiver_account_ref` is the stable, redacted Allbert-side configured
  receiver/install/account reference: Slack workspace install or team binding,
  Discord bot/application plus guild/DM scope, Telegram bot/chat account, email
  mailbox, SMS number, web workspace, or CLI profile. It is never a raw token,
  phone number, email address, or OAuth secret. It prevents collisions when the
  same provider ids appear under different configured receiver accounts today
  and under different owner scopes later.
- `provider_thread_key` is a deterministic, bounded string or hash produced from
  a canonicalized provider ref and is the value used in unique indexes.
  `provider_thread_ref` is a redacted structured map for rendering, diagnostics,
  and smoke evidence; JSON/map equality is never the database uniqueness
  contract.

### Runtime and channel event contract
- For inbound events, the parser derives `receiver_account_ref`,
  `provider_thread_ref`, and `provider_thread_key` before runtime submission.
  `ChannelThread.echo?/1` runs before `Runtime.submit_user_input/1`; an inbound
  provider message that matches a recorded outbound ref is dropped.
- If `ChannelThread.lookup_thread/1` finds an existing row for
  `{owner_scope, channel, receiver_account_ref, provider_thread_key}`, the
  adapter may pass that canonical `thread_id` into `Runtime.submit_user_input/1`
  as a previously bound Allbert thread id. If no row exists, the adapter omits
  `thread_id` and `Conversations.resolve_thread/1` creates or selects the
  canonical thread.
- After a successful runtime response, `ChannelThread.link_thread/1` binds the
  response's canonical `thread_id` to the provider thread key, and
  `record_message_ref/1` stores inbound and outbound provider message refs.
- `channel_events.thread_id`, when set after v0.52, stores only the canonical
  `conversation_threads.id`. Provider ids live in `provider_thread_ref`
  metadata and ADR 0057 mapping tables, never in `channel_events.thread_id`.

### Per-adapter threading capability
- Channel descriptors gain a **`threading:`** field (the ADR 0016 descriptor
  pattern, alongside `primitives:`), declaring one capability:
  `:native_threads` (Slack, Discord, Telegram topic chats, Matrix),
  `:reply_chain` (email, Telegram DM, WhatsApp, Signal), `:flat` (SMS), or
  `:rich` (web, CLI — Allbert controls the surface). Plus orthogonal flags:
  `can_create_thread`, `reply_key_type` (`:opaque_id | :timestamp`),
  `quote_ttl_ms` (e.g. WhatsApp 30 days). The channel registry rejects a channel
  descriptor missing/declaring an invalid `threading:` value.
- `AllbertAssist.Conversations.ChannelThread` is the single module that maps
  canonical ⇄ provider refs and picks the render strategy from the capability.
  Its public API accepts one normalized ref struct/map carrying `owner_scope`,
  `channel`, `receiver_account_ref`, `provider_thread_key`, and the redacted
  `provider_thread_ref`; callers do not hand-roll lookup keys.

### Degradation ladder (canonical → channel)
1. `:native_threads` → place in the native thread (`thread_ts` / thread channel
   / `message_thread_id` / `m.thread`).
2. `:reply_chain` → set the native reply/quote pointer (email
   `In-Reply-To`+`References`; Telegram `reply_to_message_id`; WhatsApp
   `context.message_id`; Signal quote-by-timestamp).
3. `:flat` → one stream per peer; inline a short text quote when context is
   needed; an optional cosmetic `[#id]` tag is never a parse key.
4. Last resort → drop threading, keep strict ingest order, rely on the unified
   history view.

### Ordering and echo
- Cross-channel ordering uses Allbert's own monotonic ingest sequence, never
  provider clocks (Slack `ts`, Signal/Telegram timestamps are unreliable across
  sources). Echo suppression is mandatory on every relay/outbound path.

### Cross-channel identity links (operator-explicit)
- A first-class operator-configured link declares that several per-channel
  identities are the **same person**, on top of the existing per-channel
  `identity_map`. Links are **never auto-derived** from display names, subjects,
  or weak signals. The per-channel `identity_map` remains the authentication
  gate (ADR 0016/0056); links only group already-mapped identities for the
  unified view and resume.

### Unified history view + explicit resume
- A read-mostly unified history view aggregates a canonical thread's messages
  across channels (web + CLI), redacted via `Runtime.Redactor`.
- Continuing a conversation on a *different* channel is an **explicit operator
  action** (`resume_thread_on_channel`), reusing the same canonical thread id and
  requiring the same resolved local `user_id`. There is **no** silent live
  cross-channel mirroring; E2EE-origin content (future Signal/WhatsApp) is never
  relayed to another surface without an explicit operator action.

## Consequences
- v0.52 builds genuinely new substrate: two mapping tables, the `ChannelThread`
  module, the `threading:` descriptor field + registry validation, the identity
  link layer, the unified view, and the resume action. The plan budgets
  milestones (substrate first; existing Telegram/email/web/CLI retrofitted).
- The construct is modular: the substrate is testable before any adapter
  consumes it; a channel that only declares `:rich`/`:native_threads` works
  without the degradation module.
- The v0.52 eval set covers: provider-thread-not-authority, echo-loop
  suppression, cross-channel resume same-user, threading-capability-missing
  rejection, identity-link no-auto-merge, unified-view redaction.
- ADR 0016 stays the boundary/primitive umbrella; ADR 0056 the inbound trust
  tier; ADR 0057 the threading/relay construct. Future channel packs (v0.53
  WhatsApp/Signal/Matrix) inherit the `threading:` contract without new ADR work.

## Related
- ADR 0016 (channel boundary, identity mapping, approval primitives).
- ADR 0056 (channel inbound trust tier — provider metadata never authority).
- ADR 0014 (local identity), ADR 0012 (conversation history substrate), ADR 0006
  (Security Central), ADR 0031 (settings fragments), ADR 0049 (development lanes).
- `docs/plans/v0.52-plan.md`, `docs/plans/v0.52-request-flow.md`.
