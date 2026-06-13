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

## Operator validation walkthrough (every click)

The complete linear runbook, one atomic action per step, from a blank slate to a
torn-down sandbox. **🧑 = you do it in the Discord UI; 🤖 = a shell command the
agent/release engineer runs** (you hand the agent the `.env` and they run those).
Each 🧑 step ends with the **expected result** so you know it worked before moving
on. This expands the summary in *Sandbox setup* / *Configure* above into
click-level detail; the env-var names match.

### Part 1 — create the application and bot 🧑

1. Open [discord.com/developers/applications](https://discord.com/developers/applications)
   and sign in with your **main** Discord account.
2. Click **New Application** (top-right). A dialog opens.
3. In **Name**, type `allbert-assist` (⚠️ Discord rejects any name containing the
   word "discord"). Tick the terms checkbox → click **Create**.
   *Expected:* the app's **General Information** page opens.
4. On **General Information**, find **Application ID** → click **Copy**.
   *Record it as* `ALLBERT_DISCORD_APPLICATION_ID`.
5. In the left sidebar click **Bot**.
6. Click **Reset Token**. A confirmation pop-up appears → click **Yes, do it!**.
   If your account has 2FA, type your **6-digit authenticator code** → **Submit**.
   *Expected:* a fresh token string appears with a **Copy** button.
7. Click **Copy** under the token and paste it **straight into your `.env`** as
   `ALLBERT_DISCORD_BOT_TOKEN`. (It is shown once; if you lose it, repeat step 6.)
   Never paste it into chat, a terminal argument, or a commit.
8. Still on the **Bot** page, scroll to **Privileged Gateway Intents**. Toggle
   **MESSAGE CONTENT INTENT** to ON (blue). Leave Presence and Server Members OFF.
   *Expected:* a **Save Changes** bar appears → click **Save Changes**.

### Part 2 — create a test server and add the bot 🧑

9. Open the **Discord client** (desktop app or [discord.com/app](https://discord.com/app))
   signed in as your main account.
10. In the far-left server rail, click the green **`+` (Add a Server)** button.
11. In the dialog click **Create My Own** → **For me and my friends** → in
    **Server Name** type `allbert-sandbox-server` → click **Create**.
    *Expected:* the new server opens with a `# general` channel.
12. Back in the Developer Portal, left sidebar → **OAuth2** → **URL Generator**.
13. In the **Integration Type** dropdown choose **Guild Install** (not "User
    Install").
14. Under **Scopes**, tick **`bot`**.
    *Expected:* a **Bot Permissions** panel appears below.
15. In **Bot Permissions** tick **View Channels**, **Send Messages**, and **Read
    Message History**.
16. Scroll to the bottom; the **Generated URL** field has filled in
    automatically. Click its **Copy** button. (There is no Save button — copying
    the URL is the action.)
17. Paste that URL into a **browser address bar** and press Enter.
    *Expected:* Discord shows an authorization prompt.
18. In the **"Add to Server"** dropdown pick `allbert-sandbox-server` → **Continue**
    → review permissions → **Authorize** → complete the **CAPTCHA**.
    *Expected:* a success page; the bot `allbert-assist` now appears in the
    server's right-hand member list (offline/grey until Allbert runs).

### Part 3 — prepare the second (unmapped) account 🧑

The clicker-rejection check needs a *second* Discord account that can click a
button **while your main account is also live**. Discord's account switcher keeps
only **one account active at a time**, so run the two accounts in two surfaces.

19. Keep your **main account** signed in to the **Discord desktop app**.
20. Sign a **second account** into a **different surface** at the same time: the
    Discord **web app** ([discord.com/app](https://discord.com/app)) in a normal
    browser window, OR a private/incognito window, OR a second browser profile.
    (No second account? Create one with a different email at
    [discord.com/register](https://discord.com/register).)
    *Expected:* both accounts are logged in simultaneously, each in its own window.
21. In the **desktop app** (main account), click the **server name** at the
    top-left → **Invite People** → click **Copy** on the invite link.
22. Paste that invite link into the **second account's** window → **Accept
    Invite** / **Join**.
    *Expected:* the second account appears in the server member list. Do **not**
    map this account later — staying unmapped is the whole point.

### Part 4 — copy the four ids 🧑

23. Enable Developer Mode: in the client, **⚙ User Settings** (bottom-left, next
    to your name) → **Advanced** → toggle **Developer Mode** ON.
24. Right-click the **server icon** in the left rail → **Copy Server ID** →
    `.env` `ALLBERT_DISCORD_GUILD_ID`.
25. Right-click the **target channel** name in the channel list → **Copy Channel
    ID** → `.env` `ALLBERT_DISCORD_CHANNEL_ID`.
26. Right-click **your own avatar** (bottom-left) → **Copy User ID** → `.env`
    `ALLBERT_DISCORD_USER_ID` (this maps to `alice`).
27. Open the member list (people icon, top-right) → right-click the **second
    account's** name → **Copy User ID** → `.env` `ALLBERT_DISCORD_UNMAPPED_USER_ID`.

### Part 5 — hand off; agent wires up + smokes

28. 🧑 Tell the agent **"`.env` is ready"**.
29. 🤖 Agent sources `.env`, runs the outbound smoke
    (`mix allbert.test external-smoke -- discord_slack`). 🧑 **Watch your channel:**
    the bot posts a parent message and a threaded reply. *Expected:* both appear;
    nothing for you to click.
30. 🤖 Agent runs the inbound smoke
    (`mix allbert.test external-smoke -- messaging_channel_inbound`) and tells you
    the **exact marker message** it printed. 🧑 From your **mapped account**, in
    the allowlisted channel, paste and send that exact text (an @mention of
    `@allbert-assist`). *Expected:* the agent confirms the smoke saw it reach the
    runtime and reports `gateway_ready`.

### Part 6 — live channel checks (Allbert server running)

31. 🤖 Agent configures the manual home and starts the live server, then re-runs
    `mix allbert.channels discord doctor`. *Expected:* `gateway_status=running`;
    the bot shows **online (green)** in your member list.
32. 🧑 **@mention.** In the allowlisted channel type `@allbert-assist`, select the
    bot from the autocomplete popup (it becomes a blue chip), add a question, e.g.
    `@allbert-assist what is 2+2?`, press **Enter**. *Expected:* the bot replies in
    the channel. 🤖 Agent confirms a `processed` Discord event for your user id.
33. 🧑 **DM.** Open the member list → click **`allbert-assist`** → in the popup
    card's **Message** box at the bottom type `hello allbert` → **Enter**.
    *Expected:* a DM opens and the bot replies. 🤖 Agent confirms a `processed` DM
    event. (If Discord blocks the DM: User Settings → **Privacy & Safety** → enable
    **Direct Messages from server members**, then retry.)
34. 🧑 **Approve a confirmation (mapped).** In the channel send a prompt that
    triggers a network action, e.g.
    `@allbert-assist fetch http://127.0.0.1:4052/workspace and summarize it`.
    *Expected:* the bot posts a message with **Approve** and **Deny** buttons.
    Click **Approve** as your main (mapped) account. *Expected:* the bot posts the
    resolved result. 🤖 Agent confirms the callback row is `processed` and the
    confirmation resolved.
35. 🧑 **Unmapped clicker is rejected.** Send a **second** network-action prompt so
    a fresh **Approve/Deny** pair appears. **Switch to the second account's
    window** and click **Approve** there **first**. *Expected:* an ephemeral
    "not authorized" response and the buttons do **not** resolve. You may then
    resolve it properly from the main account. 🤖 Agent confirms a `rejected`
    callback row with the second account's id and that the confirmation stayed open
    until the mapped click.

### Part 7 — hand off; agent closes out

36. 🤖 Agent restarts the server to exercise **reconnect/RESUME**, renders the
    **unified history**, runs final **raw-token leak scans**, and reports all
    evidence paths. No operator action.

### What you actually touch, in one line

Create app+bot (1–8) → make server + invite bot (9–18) → set up the 2nd account
(19–22) → copy 4 ids (23–27) → "`.env` ready" (28) → send marker msg (30) →
@mention (32) → DM (33) → approve a confirmation (34) → 2nd confirmation clicked
by the unmapped account (35) → teardown (below). Everything else is the agent.

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
