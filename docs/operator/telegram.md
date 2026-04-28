# Telegram operator guide

Telegram is the optional remote-chat operator channel in the current v0.15.0 release. The daemon remains the source of truth: Telegram renders bounded structural status, activity, approvals, traces, adapter posture, diagnosis posture, utility posture, and read-only RAG status/search without reading local files directly.

Start with the [v0.15.0 operator playbook](../onboarding-and-operations.md) for the full feature-test path.

## Provider-Free Smoke

You can verify the local channel configuration path without a bot token or live Telegram message:

```bash
tmpdir=$(mktemp -d /tmp/allbert-telegram-smoke.XXXXXX)
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- daemon channels add telegram
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- daemon channels status telegram
```

This smoke proves the CLI/config/status surface works. It does not prove live polling, allowlist matching, photo download, or Telegram delivery; those require the credentialed setup below.

## Setup

Enable Telegram through the daemon channel command:

```bash
cargo run -p allbert-cli -- daemon channels add telegram
cargo run -p allbert-cli -- daemon channels status telegram
```

The channel requires a bot token and at least one allowlisted chat. Secrets stay under `~/.allbert/secrets/`; the allowlist lives under `~/.allbert/config/`.

### Credential Discovery

Get the bot token from Telegram's BotFather:

1. In Telegram, start a chat with `@BotFather`.
2. Send `/newbot`.
3. Follow the prompts for bot name and username.
4. Copy the token BotFather returns. Use it as `TELEGRAM_BOT_TOKEN`.

Find the allowlisted chat id after you have sent at least one message to the bot:

```bash
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
```

In the `getUpdates` response, use `message.chat.id` as `TELEGRAM_CHAT_ID`.
Direct chats are usually positive numbers. Groups and supergroups are usually
negative numbers, often beginning with `-100`. Keep the full number exactly as
Telegram reports it.

Do not use the bot id from `getMe.result.id`, the top-level `update_id`, the
per-message `message.message_id`, or `message.from.id` for
`TELEGRAM_CHAT_ID`. In a response shaped like
`{"update_id":111,"message":{"message_id":17,"from":{"id":222},"chat":{"id":333}}}`,
the Telegram message id is `17`, but the allowlisted chat id is `333`; set
`TELEGRAM_CHAT_ID=333` before writing `allowed_chats` or running
`identity add-channel`.

If `getUpdates` returns an empty `result`, send `/start` or any short message to
the bot from the Telegram chat you want to allow, then run `getUpdates` again.
For a group, add the bot to the group and send a message in that group.

Write credentials into Allbert:

```bash
mkdir -p ~/.allbert/secrets/telegram ~/.allbert/config/channels.telegram
printf '%s\n' "$TELEGRAM_BOT_TOKEN" > ~/.allbert/secrets/telegram/bot_token
printf '%s\n' "$TELEGRAM_CHAT_ID" > ~/.allbert/config/channels.telegram.allowed_chats
```

`allowed_chats` accepts one numeric chat id per line. Blank lines and comments
are ignored.

### Identity Continuity

Allowlisting a chat lets Telegram talk to the bot. Identity continuity is a
separate step that maps that Telegram sender to your primary Allbert identity.
After adding the allowlist, `identity show` may print:

```text
warnings:
- 1 Telegram allowlisted sender(s) are not yet mapped into identity continuity. Use `allbert-cli identity add-channel telegram <sender>` to promote them.
migration candidates:
- telegram:7336421071
```

That means the Telegram chat is allowed, but Allbert has not yet connected it to
the same identity used by REPL, jobs, inbox approvals, and profile continuity.
Promote the candidate with the same numeric chat id:

```bash
cargo run -q -p allbert-cli -- identity add-channel telegram "$TELEGRAM_CHAT_ID"
cargo run -q -p allbert-cli -- identity show
```

Expected: `identity show` lists `telegram:<id>` under `channels`, and the
migration-candidate warning disappears. For a provider-free channel config
smoke, the warning is informational; for real Telegram operation, map the
channel. Incoming Telegram runtime sender keys may include both the chat id and
Telegram user id; a documented chat-id binding is still sufficient for identity
continuity.

After profile import on another temp profile or machine, you may see the
opposite warning:

```text
telegram sender 7336421071 is present in identity/user.md but missing from .../config/channels.telegram.allowed_chats
```

That means the identity binding traveled with the profile, but the destination
does not yet allow that Telegram chat. Recreate the local bot token and
`allowed_chats` file if this destination should use Telegram. If it should not,
remove the binding:

```bash
cargo run -q -p allbert-cli -- identity remove-channel telegram "$TELEGRAM_CHAT_ID"
```

## Commands

Telegram supports compact operator commands:

```text
/status
/activity
/trace last
/trace span <span-id>
/adapter status
/adapter approvals
/diagnose last
/utilities status
/approve <approval-id>
/reject <approval-id>
/override <reason>
/reset
```

`/status` reports the channel/runtime posture. `/activity` renders the daemon-owned `ActivitySnapshot`, including current phase, elapsed time, bounded tool summary, stuck hint, and next action when available. `/trace last` and `/trace span <span-id>` return compact, redacted structural trace summaries; prompts, responses, tool args, and tool results stay in the local session trace artifacts. `/adapter status` reports the active adapter pointer, and `/adapter approvals` lists pending adapter approvals without sending weights or diffs through Telegram. `/diagnose last` reports the latest diagnosis id, classification, confidence, and report path. `/utilities status` reports enabled utility counts and entries needing review.

## Approvals

Telegram approval prompts include the same bounded approval context as TUI, REPL, and CLI. Patch approvals may show a short diff preview, but full patch artifacts remain session-backed and install remains a separate explicit command.

Accepting an approval records review only. If a patch approval is accepted, Allbert still requires a later `self-improvement install <approval-id>` command from a local operator surface. If an adapter approval is accepted, Allbert installs the adapter but still requires explicit local activation.

Diagnosis remediation remains local-surface only. Telegram does not start `diagnose run --remediate ...`, does not enable or disable utilities, and does not run `unix_pipe`.

## Errors

Telegram turn failures append the same remediation hints as local surfaces where possible. Common examples include missing bot token, allowlist mismatch, daemon activity, provider key, cost-cap, and approval expiry guidance.

## Related Docs

- [v0.15.0 operator playbook](../onboarding-and-operations.md)
- [Telemetry operator guide](telemetry.md)
- [Tracing operator guide](tracing.md)
- [RAG operator guide](rag.md)
- [Personalization guide](personalization.md)
- [Self-diagnosis and local utilities](self-diagnosis-and-utilities.md)
- [Self-improvement guide](self-improvement.md)
- [v0.15 upgrade notes](../notes/v0.15-upgrade-2026-04-27.md)
