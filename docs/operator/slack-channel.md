# Slack Channel Operator Guide

Status: implemented in v0.52 as part of Channel Pack 1. This guide covers the
shipped Slack text channel surface: Socket Mode message/callback ingestion,
Web API message delivery through `Req`, ADR 0016 approval primitives, ADR 0056
inbound trust, and ADR 0057 cross-channel threading.

Slack Events API HTTP webhooks, distributed-app Marketplace flow,
multi-workspace OAuth, and hosted tenancy are not part of v0.52. Use an
internal, non-Marketplace Slack app for v0.52 validation.

## Requirements

- A sandbox Slack workspace and internal Slack app.
- Socket Mode enabled with an app-level token.
- A bot token stored only through Settings Central secrets. The channel CLI
  stores only `secret://` references for Slack bot/app tokens.
- Bot scopes sufficient for the current surface. The real-provider smoke needs
  `auth.test` and `chat.postMessage` access. Live inbound validation needs app
  mentions and DM message events delivered through Socket Mode, plus
  interactivity enabled for buttons.
- One mapped Slack user id, one workspace team id, and one allowlisted channel.

## Configure

Use a disposable `ALLBERT_HOME` for smoke and release validation:

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-slack.XXXXXX)"
mix ecto.migrate.allbert --quiet
```

Store the raw Slack bot token under `secret://channels/slack/bot_token` and the
raw app-level token under `secret://channels/slack/app_token` through the
Settings Central secret path available in the operator environment. Do not pass
raw Slack tokens to `mix allbert.channels slack set-token` or
`mix allbert.channels slack set-app-token`; v0.52 intentionally rejects raw
Slack token arguments.

Then store the channel settings and identity map:

```sh
mix allbert.channels slack set-token secret://channels/slack/bot_token
mix allbert.channels slack set-app-token secret://channels/slack/app_token
mix allbert.channels slack set-team-id SLACK_TEAM_ID
mix allbert.channels slack add-channel SLACK_CHANNEL_ID
mix allbert.channels slack map --external-user SLACK_USER_ID --user alice
mix allbert.settings set channels.slack.enabled true
```

For cross-channel resume, add an explicit identity link before resuming the same
canonical thread into Slack:

```sh
mix allbert.channels identity-links add --link alice-primary --channel slack --receiver slack:team:SLACK_TEAM_ID --external-user SLACK_USER_ID --user alice
mix allbert.conversations resume THREAD_ID --channel slack --user alice --receiver slack:team:SLACK_TEAM_ID --external-user SLACK_USER_ID --provider-thread-key PROVIDER_THREAD_KEY
```

## Verify

Run the deterministic local gate first:

```sh
mix allbert.test release.v052
```

Run the redacted doctor:

```sh
mix allbert.channels slack doctor
mix allbert.channels show slack
```

Before tagging v0.52, run the real-provider smoke with a sandbox workspace and
channel. `ALLBERT_TEST_KEEP_TMP=1` keeps the owned smoke home and evidence file
inspectable after the task exits:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_SLACK_BOT_TOKEN="..."
export ALLBERT_SLACK_CHANNEL_ID="..."
mix allbert.test external-smoke -- discord_slack
```

The smoke sends a real Slack parent message and a real `thread_ts` reply,
records `ChannelThread` outbound refs, asserts echo-suppression metadata, and
writes `<ALLBERT_HOME>/release_evidence/v052/external-smoke-<ts>.json`.

Then run the shared live inbound smoke. This command opens the real Discord
Gateway and Slack Socket Mode sessions, waits for Discord `READY` and Slack
`hello`, prints exact marker messages, and waits for provider-delivered inbound
messages from mapped users to reach `Runtime.submit_user_input/1`. Keep the
owned smoke home for evidence inspection:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_MESSAGING_CHANNEL_INBOUND_TIMEOUT_MS=120000
export ALLBERT_DISCORD_BOT_TOKEN="..."
export ALLBERT_DISCORD_APPLICATION_ID="..."
export ALLBERT_DISCORD_GUILD_ID="..."
export ALLBERT_DISCORD_CHANNEL_ID="..."
export ALLBERT_DISCORD_USER_ID="..."
export ALLBERT_SLACK_BOT_TOKEN="..."
export ALLBERT_SLACK_APP_TOKEN="..."
export ALLBERT_SLACK_CHANNEL_ID="..."
export ALLBERT_SLACK_USER_ID="..."
mix allbert.test external-smoke -- messaging_channel_inbound
```

The inbound smoke writes
`<ALLBERT_HOME>/release_evidence/v052/external-smoke-messaging-inbound-<ts>.json`.
It proves live channel-session connect and mapped @mention delivery for the
current Discord/Slack provider pair; it does not replace the manual DM and
button/clicker checks below.

Manual validation before tag:

- Start Allbert normally with the configured `ALLBERT_HOME`.
- If `messaging_channel_inbound` was not run successfully, send an @mention in
  the allowlisted Slack channel from the mapped user and confirm a runtime
  request is created.
- Send a DM from the mapped user and confirm a runtime request is created.
- Trigger a Slack button confirmation and verify the mapped clicker can approve
  or deny.
- Trigger the same callback shape from an unmapped or non-allowlisted user and
  verify it is rejected before confirmation resolution.
- Confirm `mix allbert.conversations show THREAD_ID --user alice` renders a
  redacted unified history and no raw token or provider payload appears.

## Troubleshooting

- `slack_doctor` reports missing settings: confirm `channels.slack.enabled`,
  `bot_token_ref`, `app_token_ref`, `workspace_team_id`, and the allowlist.
- Messages are ignored: verify the channel id is allowlisted, the sender is
  mapped, the workspace team id matches, and Socket Mode is delivering app
  mentions/DMs.
- Button callbacks do not resolve: verify Slack interactivity is enabled and the
  callback user is the same mapped user that owns the pending confirmation.
- Thread continuity looks wrong: inspect the canonical thread through
  `mix allbert.conversations show THREAD_ID --user alice`; Slack `thread_ts`
  values are routing metadata only and never Allbert `thread_id` authority.
- Token leakage suspicion: run `mix allbert.test release.v052` and inspect the
  release evidence secret scan. Raw Slack tokens must not appear in CLI output,
  traces, audits, settings output, or `channel_events`.
