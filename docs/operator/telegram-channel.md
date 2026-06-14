# Telegram Channel Operator Guide

Status: implemented in v0.53 M5 as Channel Pack 1 retro-validation. This guide
covers the shipped Telegram Bot API surface: long-poll inbound text, outbound
delivery, ADR 0016 approval buttons or typed-command fallback, ADR 0056 inbound
trust, and ADR 0057 cross-channel threading.

## Requirements

- A disposable Telegram bot created with BotFather.
- The bot token stored only through the channel CLI, which writes the raw token
  into Settings Central secrets and stores only the `secret://` reference in
  settings.
- One mapped Telegram user id and one target chat id.
- A second unmapped Telegram user for rejection checks when available.
- A disposable `ALLBERT_HOME` for release validation.

Telegram `callback_data` is limited by the provider to 1-64 bytes. v0.53 keeps
valid confirmation buttons inside that limit and falls back to typed commands
when a future confirmation id would exceed it.

## Configure

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-telegram.XXXXXX)"
mix ecto.migrate.allbert --quiet

mix allbert.channels telegram set-token "$ALLBERT_TELEGRAM_BOT_TOKEN"
mix allbert.settings set channels.telegram.enabled true
mix allbert.settings set channels.telegram.allowed_chat_ids '["'"$ALLBERT_TELEGRAM_CHAT_ID"'"]'
mix allbert.settings set channels.telegram.allow_group_chats false
mix allbert.channels telegram map --external-user "$ALLBERT_TELEGRAM_USER_ID" --user alice
```

The settings output must show `channels.telegram.bot_token_ref` as a
`secret://` value and must not print the raw bot token.

## Verify

Run the deterministic local gate first:

```sh
MIX_ENV=test mix allbert.test release.v053
```

Run the redacted doctor:

```sh
mix allbert.channels telegram doctor
mix allbert.channels show telegram
```

The doctor calls Telegram `getMe`, reports redacted credential/endpoint state,
and includes the local poller status (`running`, `disabled`, `not_started`,
`error`, or `unavailable`).

Run the outbound smoke independently. This command must not require email env:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_TELEGRAM_BOT_TOKEN="..."
export ALLBERT_TELEGRAM_CHAT_ID="..."
mix allbert.test external-smoke -- telegram
```

It sends a real Telegram parent message and reply, records `ChannelThread`
outbound refs, asserts echo-suppression metadata, and writes
`<ALLBERT_HOME>/release_evidence/v053/external-smoke-telegram-<ts>.json`.

Run the inbound smoke independently. This command must not require email env:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_TELEGRAM_INBOUND_TIMEOUT_MS=600000
export ALLBERT_SMOKE_MARKER="allbert-v053-telegram-check"
export ALLBERT_TELEGRAM_BOT_TOKEN="..."
export ALLBERT_TELEGRAM_CHAT_ID="..."
export ALLBERT_TELEGRAM_USER_ID="..."
mix allbert.test external-smoke -- inbound_telegram
```

It starts the real long-poll adapter, waits for the mapped user's marker message
to reach `Runtime.submit_user_input/1`, and writes
`<ALLBERT_HOME>/release_evidence/v053/external-smoke-inbound-telegram-<ts>.json`.

Manual validation before tag:

- Start Allbert normally with the configured `ALLBERT_HOME`.
- Send a text message from the mapped Telegram user and confirm a runtime
  request is created.
- Send a message from an unmapped user and confirm it is rejected before
  runtime.
- Trigger a confirmation and verify Telegram buttons approve/deny when
  `callback_data` fits, or typed commands are shown when fallback is required.
- Confirm replies preserve the provider reply chain and the unified conversation
  history stays redacted.
- Run `rg -i 'token|password|secret|\+[0-9]{6,}' "$ALLBERT_HOME" || true` and
  resolve any raw-token or phone-number hits before release.

## Cleanup

Revoke or rotate the BotFather token, disable the Telegram channel in the
validation home, delete temporary chats/messages when practical, and keep the
release-evidence JSON files for closeout.
