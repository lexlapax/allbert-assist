# Discord Channel Operator Guide

Status: implemented in v0.52 as part of Channel Pack 1. This guide covers the
shipped Discord text channel surface: Gateway-based message/callback ingestion,
REST message delivery through `Req`, ADR 0016 approval primitives, ADR 0056
inbound trust, and ADR 0057 cross-channel threading.

Discord Interactions HTTP webhooks, sharding, slash-command registration, voice,
and multi-install hosted tenancy are not part of v0.52.

## Requirements

- A sandbox Discord application and bot.
- Bot token stored only through Settings Central secrets. The channel CLI stores
  only the `secret://` reference for Discord.
- Bot installed in the test guild with permission to view the target channel,
  send messages, and read message history.
- Gateway intents for guild messages and direct messages. Free-text @mention/DM
  handling requires the Discord `MESSAGE_CONTENT` privileged intent; operators
  must enable it in the Discord developer portal. Large bots subject to the
  Discord privileged-intent review threshold need approval before broad guild
  deployment.
- One mapped Discord user id and one allowlisted channel. Guild messages require
  the guild id to be allowlisted; DMs do not carry a guild id.

## Sandbox setup (Discord Developer Portal)

Stand up a throwaway application and bot before configuring Allbert. All steps
are in the [Discord Developer Portal](https://discord.com/developers/applications).

1. **Create the application.** New Application → name it (e.g.
   `allbert-sandbox`). Copy the **Application ID** from General Information; this
   is `DISCORD_APPLICATION_ID`.
2. **Create the bot + token.** Bot page → Reset Token → copy the bot token once
   (it is shown only once). This is the value you store under the `secret://`
   ref below — never paste it into a CLI argument or commit it.
3. **Enable the privileged intent.** On the Bot page, under *Privileged Gateway
   Intents*, toggle **MESSAGE CONTENT INTENT** on. Without it the Gateway
   connects but `message_create` payloads arrive with empty `content`, so
   free-text @mention/DM handling silently fails. (Also leave Server Members
   off — Allbert does not need it.) The doctor flags a missing
   `message_content` intent in `channels.discord.gateway_intents`, but the
   portal toggle is the provider-side half and must also be on.
4. **Invite the bot to a sandbox guild.** OAuth2 → URL Generator → select the
   `bot` scope, then under Bot Permissions select **View Channels**, **Send
   Messages**, and **Read Message History**. Open the generated URL and add the
   bot to a disposable test guild you own. Note the guild id
   (`DISCORD_GUILD_ID`) and the target channel id (`DISCORD_CHANNEL_ID`) with
   Developer Mode enabled in the Discord client (right-click → Copy ID).
5. **Note the test user id.** Right-click your own account → Copy ID. This is the
   `DISCORD_USER_ID` you map to a local Allbert user.

Bots in 75+ guilds must pass Discord privileged-intent verification before the
`message_content` intent keeps working; a single sandbox guild is well under
that threshold.

## Configure

Use a disposable `ALLBERT_HOME` for smoke and release validation:

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-discord.XXXXXX)"
mix ecto.migrate.allbert --quiet
```

Store the raw bot token under `secret://channels/discord/bot_token` through the
Settings Central secret path available in the operator environment. Do not pass
the raw token to `mix allbert.channels discord set-token`; v0.52 intentionally
rejects raw Discord token arguments.

Then store the channel settings and identity map:

```sh
mix allbert.channels discord set-token secret://channels/discord/bot_token
mix allbert.channels discord set-application-id DISCORD_APPLICATION_ID
mix allbert.channels discord add-guild DISCORD_GUILD_ID
mix allbert.channels discord add-channel DISCORD_CHANNEL_ID
mix allbert.channels discord map --external-user DISCORD_USER_ID --user alice
mix allbert.settings set channels.discord.enabled true
```

For cross-channel resume, add an explicit identity link before resuming the same
canonical thread into Discord:

```sh
mix allbert.channels identity-links add --link alice-primary --channel discord --receiver discord:app:DISCORD_APPLICATION_ID:guild:DISCORD_GUILD_ID --external-user DISCORD_USER_ID --user alice
mix allbert.conversations resume THREAD_ID --channel discord --user alice --receiver discord:app:DISCORD_APPLICATION_ID:guild:DISCORD_GUILD_ID --external-user DISCORD_USER_ID --provider-thread-key PROVIDER_THREAD_KEY
```

## Verify

Run the deterministic local gate first:

```sh
mix allbert.test release.v052
```

Run the redacted doctor:

```sh
mix allbert.channels discord doctor
mix allbert.channels show discord
```

The doctor reports the **live** Gateway transport status (`running` when the
adapter holds an open Gateway session, `disabled` when the channel is off,
`error`/`not_started` otherwise) — not a placeholder — so run it against a
running Allbert to confirm the session is actually up. It also flags
`missing_message_content_intent` when `channels.discord.gateway_intents` omits
`message_content` (the Allbert-side half of step 3 above).

Before tagging v0.52, run the real-provider smoke with a sandbox bot/channel.
`ALLBERT_TEST_KEEP_TMP=1` keeps the owned smoke home and evidence file
inspectable after the task exits:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_DISCORD_BOT_TOKEN="..."
export ALLBERT_DISCORD_CHANNEL_ID="..."
export ALLBERT_DISCORD_GUILD_ID="..."
mix allbert.test external-smoke -- discord_slack
```

The smoke sends a real Discord parent message and a real
`message_reference` reply, records `ChannelThread` outbound refs, asserts
echo-suppression metadata, and writes
`<ALLBERT_HOME>/release_evidence/v052/external-smoke-<ts>.json`.

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
  the allowlisted guild channel from the mapped user and confirm a runtime
  request is created.
- Send a DM from the mapped user and confirm a runtime request is created.
- Trigger a Discord button confirmation and verify the mapped clicker can
  approve or deny.
- Trigger the same callback shape from an unmapped or non-allowlisted user and
  verify it is rejected before confirmation resolution.
- Confirm `mix allbert.conversations show THREAD_ID --user alice` renders a
  redacted unified history and no raw token or provider payload appears.

## Cleanup / teardown

After validation, tear the sandbox down so no live credential or bot lingers:

1. **Disable the channel** so Allbert stops opening the Gateway:
   `mix allbert.settings set channels.discord.enabled false`. Confirm
   `mix allbert.channels discord doctor` now reports `gateway_status=disabled`.
2. **Reset the bot token** in the Developer Portal (Bot → Reset Token). This
   immediately invalidates the token Allbert held, even if a copy leaked.
3. **Remove the bot from the test guild** (Server Settings → Integrations →
   the bot → Remove), or delete the disposable guild entirely.
4. **Delete the application** in the Developer Portal (General Information →
   Delete App) if the sandbox is no longer needed.
5. **Discard the disposable home and its evidence:**
   `rm -rf "$ALLBERT_HOME"` (skip if you are keeping the
   `release_evidence/v052/` artifacts for the release record — copy them out
   first). Unset the `ALLBERT_DISCORD_*` env vars holding raw tokens:
   `unset ALLBERT_DISCORD_BOT_TOKEN ALLBERT_DISCORD_APPLICATION_ID ALLBERT_DISCORD_GUILD_ID ALLBERT_DISCORD_CHANNEL_ID ALLBERT_DISCORD_USER_ID`.

## Troubleshooting

- `discord_doctor` reports missing settings: confirm `channels.discord.enabled`,
  `bot_token_ref`, `application_id`, and the allowlists.
- Messages are ignored: verify the guild/channel ids match the message context,
  the sender is mapped, and `MESSAGE_CONTENT` is enabled for free-text
  @mentions/DMs.
- Thread continuity looks wrong: inspect the canonical thread through
  `mix allbert.conversations show THREAD_ID --user alice`; provider thread ids
  are routing metadata only and never Allbert `thread_id` authority.
- Token leakage suspicion: run `mix allbert.test release.v052` and inspect the
  release evidence secret scan. Raw Discord tokens must not appear in CLI
  output, traces, audits, settings output, or `channel_events`.
