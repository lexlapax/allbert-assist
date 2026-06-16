# ADR 0063: Outbound Compose Actions — Email, Calendar & Channel Send

Status: Accepted (v0.54 M10; in-scope for v0.54, gates the tag — operator decision
2026-06-16). Implementation-ready; backing APIs verified against the codebase.
Date: 2026-06-16
Related: ADR 0060 (router + approval-gate separation), ADR 0062 (descriptor
lifecycle — these actions declare descriptors picked up automatically), ADR 0016
(channel adapter boundary + identity mapping), ADR 0056 (channel inbound trust
tier), ADR 0059 (channel trust-class + relay gating), ADR 0006 (Security Central),
ADR 0047 (doctor envelope). MCP tool calls per the existing `actions/mcp/` surface.

## Context

The M9 zoom-out of the action surface (v0.54-plan.md) found high-frequency user
intents the router can recognize but **cannot execute**, because no executable
action exists — only delivery infrastructure or a read-only workspace panel:

- **Send/draft email** — the email plugin sends only *replies* to inbound messages
  (`Channels.Email.SmtpClient.send/5` via the adapter's `deliver_reply`); there is
  no agent-facing compose/send-to-arbitrary-recipient action. `open_mail_panel` is a
  read-only handoff.
- **Create calendar event** — there is **no calendar backend at all**; only
  `open_calendar_panel` (a read-only workspace handoff).
- **Send/compose a channel message** — channel adapters are inbound/outbound
  *delivery* infrastructure (e.g. Slack `Client.chat_post_message/3`); there is no
  operator-facing compose/send action, and outbound sends to arbitrary targets are
  not gated by an action-level policy.

These are real feature work with their own authority/confirmation surfaces, distinct
from the router. M9 makes them *routable* once descriptors exist; M10 (this ADR)
makes them *executable* safely.

## Decision

Add three NEW effectful, agent-exposed actions following one shared pattern, each
declaring its own intent descriptor (consumed by the ADR 0062 lifecycle).

### Shared action pattern (mirror `generate_image`)

`use AllbertAssist.Action` with `exposure: :agent`, `confirmation: :required`,
`resumable?: true`, a per-action `permission` and `execution_mode`, and a slot
`schema`. `run/2` flow:

1. validate slots → `Security.PermissionGate.authorize(permission, ctx)`.
2. **outbound-target gating happens here, before any send** (see below).
3. `decision == :needs_confirmation` → `Confirmations.create/1` with a redacted
   `params_summary` and a `resume_params_ref` → return `status: :needs_confirmation`
   + `confirmation_id`.
4. resume via `approve_confirmation` → perform the outbound send → return
   `:completed` (or `:denied`). Deny cancels with no side effect.

Routing to these actions grants no authority (ADR 0060); the confirmation gate is
the sole execution boundary; the router never auto-sends.

Before the three actions are implemented, M10 must land the shared execution
contracts they depend on:

- **Permissions:** register `:email_send`, `:channel_message_send`, and
  `:calendar_write` across Security Policy, Risk floors, Settings Schema defaults /
  safe-write keys, and the security eval inventory. Each defaults to a
  `:needs_confirmation` floor.
- **Generic resumable confirmation resume:** approval of any registered action with
  `resumable?: true` and a stored `resume_params_ref` re-runs that action through
  `Actions.Runner.run/3` after the permission re-check. Non-resumable or unknown
  action families still fail closed; approval does not create a hidden adapter path.
- **Outbound boundary:** `send_channel_message` calls
  `AllbertAssist.Channels.Outbound.send/4` (or the equivalent adapter behaviour
  callback), implemented for every connected adapter before the action ships. The
  action never calls provider clients directly.

### `send_email`

- `app_id: :email`, `permission: :email_send`, `execution_mode: :smtp_send`.
- slots: `to` (required), `subject`, `body` (required), optional `cc`, `from_name`.
- backend: resolve creds via the email adapter `resolve_credentials/1` (smtp_host,
  smtp_port, smtp_username, from_address; password via `Secrets.get_secret/1`) →
  `Channels.Email.SmtpClient.send(from, to, subject, body, opts)`.
- summary redacts the body; `to`/`subject` shown. No raw secrets in summary/trace.

### `send_channel_message`

- `permission: :channel_message_send`, `execution_mode: :channel_post`.
- slots: `channel` (required), `target` (thread/conversation/user, required), `body`
  (required).
- **gating (the heart of this action):** before send, resolve `target` against the
  channel identity allowlist (`Channels.Identity.resolve/3` →
  `{:ok,user_id}|{:error,:not_mapped|:disabled}`) and enforce the trust-class floor
  (`:server_readable` unless explicitly approved; ADR 0059). A send to an
  un-allowlisted/disabled target is **rejected before dispatch**, not confirmed.
- backend: `AllbertAssist.Channels.Outbound.send/4`, which dispatches to the
  per-channel adapter outbound path (e.g. Slack `Client.chat_post_message/3`);
  record provenance via
  `Conversations.ChannelThread.record_message_ref/1`.

### `create_calendar_event` (MCP-backed)

- `permission: :calendar_write`, `execution_mode: :mcp_tool_call`.
- slots: `title` (required), `start` (required), `end`/`duration`, optional
  `attendees`, `location`.
- backend: route through a connected **Google Calendar MCP server** via the existing
  MCP `call_tool` path (`actions/mcp/`). No new OAuth/credential custody in Allbert;
  the MCP server owns the calendar credential. The MCP `call_tool` is itself
  `confirmation: :required`, so the calendar write is double-gated.
- **fallback:** if no calendar MCP server is connected, the action degrades
  gracefully to a `:answer` ("I can't create calendar events yet — connect a
  calendar MCP server") — never a hard failure or dead-end.

Calendar via MCP was chosen over native Google OAuth (operator decision 2026-06-16)
as the lightest lift that reuses existing MCP auth + confirmation and adds no new
credential custody.

## Authority & security invariants

- Effectful + outbound → `confirmation: :required`, registry-validated, Security
  Central permission. The router selecting one of these grants no authority
  (ADR 0060); execution requires explicit approval.
- Channel/email sends enforce **identity-allowlist + trust-class gating inside the
  action, before dispatch** (ADR 0016/0056/0059). No sends to un-allowlisted
  targets; no trust-class downgrade without explicit approval.
- Calendar reuses the MCP call confirmation; no calendar credential enters Allbert.
- Secrets (SMTP password, tokens) are never placed in confirmation summaries,
  params_summary, traces, or audits — redacted (ADR 0047 posture).
- These actions add no new authority path: they are ordinary registry actions behind
  the existing confirmation gate.

## Consequences

- New actions `send_email`, `send_channel_message`, `create_calendar_event`; new
  permissions `:email_send`, `:channel_message_send`, `:calendar_write`;
  descriptors for each (ADR 0062 indexes them). M10 `:v054` eval rows
  (send-email-confirmed, channel-target-gated, calendar-mcp-backed,
  outbound-grants-no-authority, generic-resume, permission-floors).
- The M9 golden-set rows for "send an email…", "schedule a meeting…", "send a slack
  message…" flip from `handoff`/`answer` to `execute`.
- v0.54 footprint grows (M10 gates the tag); calendar depends on an external MCP
  server being connected (graceful degrade otherwise).

## Alternatives considered

- **Native Google Calendar OAuth client** (parallel to the email plugin). Rejected
  for v0.54: heaviest lift, new credential custody, its own ADR — disproportionate
  vs. the MCP path.
- **Leave these as panel handoffs.** Rejected: the whole point of M9/M10 is that the
  workflow must execute, not dead-end at a panel.
- **Auto-send without confirmation for "trusted" targets.** Rejected: outbound
  email/messages are effectful and externally visible; confirmation is mandatory.
