# ADR 0016: Channel Adapter Boundary And Identity Mapping

Status: Accepted

Date: 2026-05-14

## Context

Allbert began with CLI and LiveView as local operator surfaces. v0.16 adds the
first two remote channels, Telegram and email, while preserving the signal-first
Jido runtime, Security Central, durable confirmations, Resource Access Security
Posture, local workspace identity, and app registration decisions made in earlier
ADRs.

External channels bring external identities, provider APIs, callbacks, delivery
failures, and duplicate inbound events. Without a clear boundary, a channel
adapter could accidentally become a second runtime, a second security policy,
or an implicit account system.

Several design questions arose in planning v0.16:

**Why long polling instead of webhooks (Telegram)?** Long polling requires no
public inbound HTTP endpoint, no TLS certificate management, and no
port-forwarding. It works locally with zero infrastructure. Webhooks are a
future option but require a public URL and are deferred.

**Why IMAP polling instead of IMAP IDLE or email API (email)?** IMAP PUSH/IDLE
requires a persistent connection and connection re-issue handling that adds
complexity for a first adapter. Email provider APIs (Mailgun/SendGrid inbound,
Gmail API) require OAuth or webhook infrastructure. Plain IMAP polling with
bounded poll intervals works with any IMAP server and zero public URL
requirements. IMAP IDLE and provider API are left as documented placeholders
for a future release.

**Why a separate `channel_events` table instead of annotating conversation
history?** `Thread`/`Message` rows (v0.12) own ordered conversation content
and are the source of truth for what was said. `channel_events` own the
provider-level transport metadata: which provider update id or Message-ID
arrived, what its delivery status was, which external identity sent it, whether
it was a duplicate, and what channel-level errors occurred. Mixing these concerns
into `Thread`/`Message` would couple the conversation model to provider-specific
fields and make dedup logic depend on conversation semantics.

**Why derive Telegram polling offset from `channel_events` instead of a
separate state row?** The maximum `external_event_id` among processed inbound
and callback events is already the correct resume offset. A separate state row
would need to be kept in sync with `channel_events` insertions and would be an
additional failure surface. Deriving it from `channel_events` at startup is
idempotent and requires no extra write path.

**Why use RFC Message-ID as the email dedup key instead of an offset?** Email
does not have a monotonic server-assigned update id like Telegram. Message-ID is
globally unique per RFC 2822 and is stable across IMAP session restarts. The
IMAP `\Seen` flag provides a second dedup guard: if the adapter crashes before
marking `\Seen`, it will re-fetch the message, but the `channel_events` unique
index prevents double-processing.

**Why a SHA-256 hash for `session_id`?** External user identifiers from Telegram
(integer user ids) and email (from-addresses) are provider-specific strings that
could collide with operator-created session ids or become atoms if stored
carelessly. A bounded, non-reversible hash is safe to store in ETS, in
`channel_events`, and in runtime request metadata without creating atoms or
leaking external identifiers. Telegram session ids include the chat id in the
hash input so a single Telegram user in two different group chats gets different
sessions; email session ids use only the sender address since email has no chat
concept.

**Why SMTP via gen_smtp instead of a provider API?** gen_smtp is OTP-native,
mature, and works with any SMTP server without external account setup. Provider
APIs (Mailgun, SendGrid) add OAuth or API key management that is a separate
secret surface. gen_smtp is the right first delivery adapter; provider API is a
documented placeholder for a future release.

## Decision

Channel adapters are delivery adapters around
`AllbertAssist.Runtime.submit_user_input/1` and registered Jido actions. They
normalize inbound provider messages, resolve configured local identity, submit
runtime requests, render responses, and record durable channel event metadata.

Channels do not own:

- intent selection
- action execution
- Security Central policy
- Resource Access grants
- confirmation storage or private mutation
- conversation history
- markdown memory
- app registry semantics

The canonical local identity remains string `user_id` from ADR 0014. External
provider identities map to local `user_id` values only through explicit
Settings Central configuration. No external identity may implicitly claim
`"local"` or any other existing local user.

For v0.16, Telegram and email are the first two proving adapters.

ADR 0017 later moves Telegram and email registration into shipped source-tree
Allbert plugins under `./plugins/allbert.telegram` and
`./plugins/allbert.email`. That packaging change does not change this channel
boundary: Telegram and email remain delivery adapters around the runtime and
registered actions.

Telegram: user IDs map to local users through `channels.telegram.identity_map`.
The bot token is stored through Settings Secrets and referenced by
`channels.telegram.bot_token_ref`. Inbound updates arrive via long polling
(`getUpdates`). Approval Handoff is rendered as inline keyboard buttons when
callback data fits the compact format, or as typed commands when it does not.

Email: sender addresses (from-address) map to local users through
`channels.email.identity_map`. IMAP credentials are stored through Settings
Secrets. Inbound messages are fetched by polling UNSEEN messages. Approval
Handoff is rendered as plain-text typed commands (`ALLBERT:APPROVE:<id>`,
`ALLBERT:DENY:<id>`, `ALLBERT:SHOW:<id>`) that the user sends back in a reply.
Outbound replies use SMTP via gen_smtp. IMAP IDLE and SMTP provider APIs are
explicitly deferred with documented placeholders.

## v0.43 Browser Confirmation Forward Pin

Browser navigation, click, and screenshot review introduced in v0.43 fit the
existing channel boundary and the v0.44 approval-primitive amendment:

- CLI and email can express approval through `:typed_command`.
- LiveView and Telegram can express approval through `:button`.
- Screenshot/cache review can be expressed as `:link`.

These primitives carry confirmation intent only. They do not grant browser
authority, remembered Resource Access grants, or app scope by themselves.

Channel adapters may use a bounded provider client for receive/send operations
against the configured provider API. This provider transport is not a general
remote access primitive and does not authorize arbitrary HTTP requests, media
downloads, document extraction, package installs, skill imports, or browser
automation.

Inbound and callback provider events are recorded in SQLite `channel_events`
for dedupe, status, and traceability. Conversation text remains in v0.12
SQLite `Thread`/`Message` history after runtime acceptance. Channel events keep
redacted/truncated summaries rather than full raw provider payload dumps.

Email attachments are never downloaded, extracted, parsed, rendered, forwarded
to the runtime, or used as memory.

Provider callback actions, such as Telegram approve/deny buttons and email
approve/deny typed commands, resolve existing durable confirmations through
registered confirmation actions and `AllbertAssist.Actions.Runner`. Callback
data and typed command patterns must not embed resource targets, shell commands,
URLs, prompt text, credentials, or remembered grant powers.

The two adapters are supervised independently under `:one_for_one` in
`AllbertAssist.Channels.Supervisor`. A crash or misconfiguration in one adapter
does not restart or disable the other. After v0.17, the same supervisor starts
them from registered channel plugin descriptors rather than a hardcoded child
list.

## Consequences

- v0.16 can add Telegram and email without creating hosted accounts or
  role-based auth.
- Tests can prove channel behavior using simulated updates and a test provider
  client (`Req.Test` for Telegram; simulated IMAP/SMTP message injection for
  email) without depending on live network access, real bot tokens, or real
  mail servers.
- The channel substrate (`AllbertAssist.Channels`), event dedupe model
  (`channel_events`), identity mapping posture
  (`AllbertAssist.Channels.Identity`), session_id derivation, and response
  rendering pattern are provider-neutral. Adding a new provider requires a new
  plugin-contributed Adapter/Client(s)/Renderer/Parser triple; the rest of the
  substrate is reused.
- Telegram polling offset is resilient: adapter restarts derive the correct
  offset from `channel_events` without a separate state table, and the partial
  unique index provides a second dedup guard.
- Email dedup is resilient: the IMAP `\Seen` flag prevents re-fetch on normal
  restarts; the `channel_events` unique index on Message-ID prevents
  double-runtime submission even if `\Seen` is not set before a crash.
- `session_id` values for Telegram sessions are stable, bounded, and safe to
  store as strings in ETS, SQLite, and runtime metadata. Telegram includes
  chat id in the hash so group and private chats get separate sessions. Email
  session ids use only the sender address since email has no chat concept.
- v0.28 (formerly v0.26) security evals have concrete cross-channel surfaces
  to test:
  identity spoofing, callback replay, command injection in email reply bodies,
  resource-scope leakage, provider payload injection, cross-user thread leakage,
  secret redaction in provider error responses, and attachment bypass attempts.
- IMAP IDLE, SMTP provider API, webhooks, media downloads, and arbitrary
  provider method exposure require a new ADR or a future v0.16+ plan revision;
  this ADR intentionally excludes them with documented placeholders.

## Deferred

- Hosted accounts, OAuth, roles, and remote multi-user administration.
- Telegram webhooks and public inbound HTTP routing.
- IMAP IDLE for push-based email delivery (placeholder in v0.16 adapter code).
- SMTP provider API (Mailgun, SendGrid) for transactional sending (placeholder
  in v0.16 adapter code).
- Email attachment download, extraction, and content forwarding.
- HTML email parsing or rich email rendering.
- SMS, Discord, Slack, native app, browser, MCP channels, and richer email
  modes beyond the v0.16 Telegram and email proving adapters.
- Media/document download and deep remote document extraction.
- Proactive broadcast and scheduled outbound messaging.
- UI protocol interop and workspace-native channel surfaces.

## v0.44 Amendment: Channel Approval Primitives

Status: Proposed for v0.44 Channel Pack 1 - Discord And Slack
(`docs/plans/v0.44-plan.md`). Becomes binding for v0.44 and all later
channel adapters including v0.50 mobile channels.

M5 closeout flips this line to `Accepted for v0.44 Channel Pack 1 -
Discord And Slack` per the §"M5 Closeout Discipline" checklist in the
plan.

### Context

v0.16 shipped two adapters with two different approval-rendering shapes:
Telegram inline keyboard buttons and email typed commands. v0.17 packaged
both as plugin adapters but did not formalize the rendering contract. By
v0.44 (Discord + Slack), the field needs Discord buttons / Slack Block Kit;
v0.50 mobile channels need WhatsApp typed commands, Signal typed commands,
and Matrix buttons-or-typed-commands. Without a formal primitive set, each
adapter would re-invent its own Approval Handoff rendering.

### Decision

Approval Handoff renders through one of four standardized primitives. Every
channel adapter declares its supported subset in its plugin descriptor:

- **`:list`** — render the pending request as text plus a numbered list of
  options (approve, deny, show, defer). Operator picks by number in a reply.
  Universal fallback; every adapter supports `:list` so Approval Handoff
  always has a delivery path.
- **`:button`** — render an interactive button affordance (Telegram inline
  keyboard, Discord component, Slack Block Kit, Matrix message buttons).
  Operator taps a button; callback resolves the confirmation.
- **`:typed_command`** — render a textual command syntax (`ALLBERT:APPROVE:<id>`)
  the operator types back in a reply. Email and text-first messaging
  surfaces (Signal, WhatsApp without Business interactive buttons).
- **`:link`** — render a deep-link into the operator's workspace surface so
  approval happens out-of-channel. Mobile channels with limited
  interactivity often render this alongside `:typed_command`.

### Selection Rule

`AllbertAssist.Approval.Handoff.render/2` (or its equivalent boundary) selects
the highest-fidelity primitive the adapter declares, in order:
`:button > :typed_command > :link > :list`.

### Adapter Declarations

Adapter declarations as of v0.50:

| Adapter   | Declared primitives                                  |
|-----------|------------------------------------------------------|
| CLI       | `:list`                                              |
| LiveView  | `:button` (workspace modal)                          |
| Telegram  | `:button`, `:typed_command`, `:list`                 |
| Email     | `:typed_command`, `:list`                            |
| Discord   | `:button`, `:typed_command`, `:list`                 |
| Slack     | `:button`, `:typed_command`, `:list`                 |
| WhatsApp  | `:typed_command`, `:link`, `:list`                   |
| Signal    | `:typed_command`, `:link`, `:list`                   |
| Matrix    | `:button` (bot rooms), `:typed_command`, `:list`     |

Adapters MUST always declare `:list` as a fallback. Adapters that ship without
declaring the supported set MUST be rejected by the channel registry.

The declarations live in the channel descriptor map returned by
`<Plugin>.channels/0`, in a new `primitives:` field added at v0.44:

```elixir
%{
  channel_id: "telegram",
  # ...existing v0.17 descriptor fields...
  primitives: [:button, :typed_command, :list]   # v0.44 amendment
}
```

`AllbertAssist.Plugin.Registry` validates the field at plugin
discovery and rejects descriptors missing the field, declaring an
empty list, declaring an unknown primitive, or omitting `:list`. The
selection rule consumes the field at the `Approval.Handoff.render/2`
boundary (see plan §"Approval Primitive Selection"); existing
Telegram + email renderers consume the selected primitive instead of
hand-rolling their choice (v0.44 M0).

### Non-Goals For This Amendment

- No channel-specific approval logic in core. The primitive set is closed; new
  primitives require an ADR amendment, not adapter-level invention.
- No new permission classes or confirmation shapes.
- No bypass of `Actions.Runner.run/3`, Security Central, or the durable
  confirmation store.
- No primitive that returns rich operator input beyond the four
  approve/deny/show/defer verbs.

### Consequences

- v0.44 lands Discord and Slack with `:button` rendering through the same
  Approval Handoff path as Telegram.
- v0.50 lands WhatsApp/Signal/Matrix with explicit primitive declarations
  rather than ad-hoc rendering.
- The v0.51 cross-surface eval sweep adds an `approval-primitive-honor`
  check per adapter.
- v1.0 freezes the channel-adapter boundary including this primitive
  contract.
