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

1. **Create the application.** New Application → name it **`allbert-assist`**
   (Discord **rejects any application name containing the word "discord"**, so do
   not use `allbert-discord` or similar — `allbert-assist` is the recommended
   allbert-unique name and matches the client identity Allbert presents on the
   Gateway). Copy the **Application ID** from General Information; this is
   `DISCORD_APPLICATION_ID`.
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
4. **Create a disposable test server ("guild").** Discord's API calls a server a
   *guild*; a "disposable test guild" just means a throwaway Discord **server you
   create and own**. In the Discord desktop/web client, click the **`+`** ("Add a
   Server") at the bottom of the left server rail → **Create My Own** → **For me
   and my friends** → name it (e.g. `allbert-sandbox-server`) → **Create**. You
   are its owner, so you can add the bot now and delete the whole server during
   teardown.
5. **Invite the bot to that server.** Developer Portal → **OAuth2 → URL
   Generator**:
   1. **Integration Type** dropdown → choose **Guild Install** (this is the
      add-to-a-server flow; "User Install" installs the app onto a user account,
      which Allbert does not use).
   2. **Scopes** → check **`bot`**.
   3. A **Bot Permissions** panel appears → check **View Channels**, **Send
      Messages**, **Read Message History**.
   4. There is **no Save button** — the page auto-builds a **Generated URL** at
      the bottom. Click **Copy**.
   5. **Paste the URL into a browser** and press Enter → in the prompt's **"Add
      to Server"** dropdown pick your test server → **Continue** → **Authorize** →
      complete the CAPTCHA. The bot now appears in that server's member list.
6. **Collect the ids.** First enable Developer Mode: click the **gear (User
   Settings)** at the bottom-left next to your name → **Advanced** → toggle
   **Developer Mode** on (turns blue). That adds a **Copy …​ ID** item to
   right-click menus across the app (older clients label it just **Copy ID**).
   All four ids are numeric snowflakes:
   - **Server id** → in the **left server rail**, right-click the test server's
     icon → **Copy Server ID** → `DISCORD_GUILD_ID`.
   - **Channel id** → in the **channel list**, right-click the target text
     channel's name → **Copy Channel ID** → `DISCORD_CHANNEL_ID`.
   - **Your user id** → right-click **your own avatar** at the bottom-left (next
     to your name) → **Copy User ID** → `DISCORD_USER_ID` (the user you map to
     `alice`). Equivalently, open the server's member list on the right,
     right-click your name → **Copy User ID**.
   - **Unmapped user id** → have a **second Discord account** join the test
     server (it must be able to see the channel but is *not* mapped to `alice`),
     then in the **member list** right-click that account's name → **Copy User
     ID** → `DISCORD_UNMAPPED_USER_ID`. (Used later to prove an unmapped clicker
     is rejected.) If you cannot get a second account into the server, you can
     instead capture its id from any message it posts — right-click the message
     author's name → **Copy User ID**.

Bots in 75+ servers must pass Discord privileged-intent verification before the
`message_content` intent keeps working; a single sandbox server is well under
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
