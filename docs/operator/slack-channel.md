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

## Sandbox setup (Slack app config)

Stand up a throwaway internal app before configuring Allbert. All steps are at
[api.slack.com/apps](https://api.slack.com/apps) → Create New App → **From
scratch** (name it **`allbert-assist`**, matching the Discord app), installed
into a disposable sandbox workspace you own.

1. **Bot token scopes.** Features → OAuth & Permissions → *Bot Token Scopes*,
   add **`app_mentions:read`** (receive @mentions), **`im:history`** (read DM
   message events), and **`chat:write`** (post replies). These three are exactly
   the set the doctor diffs against; missing any is flagged as
   `missing_bot_scopes`.
2. **Enable Socket Mode.** Settings → Socket Mode → toggle **Enable Socket
   Mode** on. This lets the app receive events over a WebSocket with no public
   Request URL.
3. **App-level token.** Settings → Basic Information → *App-Level Tokens* →
   Generate Token and Scopes → add the **`connections:write`** scope. The token
   starts with `xapp-`; this is `SLACK_APP_TOKEN`. (`connections:write` is what
   lets the app open the Socket Mode WebSocket; it is validated implicitly when
   the socket connects, separately from the bot-token scope diff.)
4. **Event subscriptions.** Features → Event Subscriptions → Enable Events, then
   under *Subscribe to bot events* add **`app_mention`** and **`message.im`**
   (DMs). Save.
5. **Interactivity.** Features → Interactivity & Shortcuts → toggle on so
   approval buttons (`block_actions`) are delivered. With Socket Mode on, no
   Request URL is required.
6. **Install the app + copy the bot token.** Features → OAuth & Permissions →
   **Install to Workspace** (or *Reinstall* after scope changes) → Allow. On the
   same page copy the **Bot User OAuth Token** (`xoxb-…`) → `SLACK_BOT_TOKEN`.
   In the workspace, `/invite @allbert-assist` into the test channel.
7. **Collect the ids.** All of these are easiest from Slack opened in a **web
   browser** ([app.slack.com](https://app.slack.com)); member ids are
   desktop/web only (not visible on mobile):
   - **Team id** (`SLACK_TEAM_ID`, starts with `T`): the segment after
     `/client/` in the browser URL — `app.slack.com/client/`**`Txxxxxxxx`**`/…`.
   - **Channel id** (`SLACK_CHANNEL_ID`, starts with `C`): right-click the
     channel in the sidebar → **View channel details** → scroll to the bottom for
     the **Channel ID**; or read the `C…` segment in the channel's URL.
   - **Your user id** (`SLACK_USER_ID`, starts with `U`): click your avatar →
     **Profile** → the **⋮ (More)** menu → **Copy member ID**. This is the id you
     map to `alice`.
   - **Unmapped user id** (`SLACK_UNMAPPED_USER_ID`): a *second* workspace member
     who is NOT mapped to `alice` (used later to prove an unmapped clicker is
     rejected). Add them to the workspace if needed, then click their
     name/avatar (in the member list or on a message they posted) → **View full
     profile** → **⋮ (More)** → **Copy member ID**.
   - **DM channel id** (`SLACK_DM_CHANNEL_ID`, starts with `D`): open your direct
     message with the bot, then read the `D…` segment in the browser URL —
     `app.slack.com/client/Txxx/`**`Dxxxxxxxx`**. DMs have no "View channel
     details" panel, so the URL is the reliable source. This id is only used to
     confirm the manual DM check landed on the right conversation; it is **not**
     added to the channel allowlist (M8R6 gates DMs by the identity map).

Use an internal (non-Marketplace) app; distributed-app OAuth and multi-workspace
install are out of scope for v0.52.

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

The doctor reports the **live** Socket Mode transport status (`running` when the
adapter holds an open Socket Mode session, `disabled` when the channel is off,
`error`/`not_started` otherwise) — not a placeholder — so run it against a
running Allbert to confirm the session is actually up. It also captures the bot
token's granted OAuth scopes (`X-OAuth-Scopes`) and flags `missing_bot_scopes`
with the specific missing scope names when `app_mentions:read`, `im:history`, or
`chat:write` is absent. Token values never appear in the output.

DM behavior is governed by `channels.slack.response_style`
(`mention` | `always` | `dm_only`, default `mention`): DMs are admitted under
`mention`/`always`/`dm_only` and gated by the identity map (not the channel
allowlist), while `dm_only` also suppresses channel @mentions. Provider echoes
(the bot's own posts, other bots, and edit/delete tombstones) are dropped before
any `channel_events` row is written.

Before tagging v0.52, run the real-provider smoke with a sandbox workspace and
channel. `ALLBERT_TEST_KEEP_TMP=1` keeps the owned smoke home and evidence file
inspectable after the task exits:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_SLACK_BOT_TOKEN="..."
export ALLBERT_SLACK_CHANNEL_ID="..."
mix allbert.test external-smoke -- slack
```

(Use `-- slack` to validate Slack alone; `-- discord_slack` runs both providers
and additionally requires the Discord creds.)

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

For Slack alone, run `-- inbound_slack` and export only the `ALLBERT_SLACK_*`
vars; the combined `messaging_channel_inbound` above additionally requires the
Discord creds.

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

## Operator validation walkthrough (every click)

The complete linear runbook, one atomic action per step, from a blank slate to a
torn-down sandbox. **🧑 = you do it in the Slack UI; 🤖 = a shell command the
agent/release engineer runs.** Each 🧑 step ends with the **expected result**.
This expands *Sandbox setup* / *Configure* above into click-level detail; the
env-var names match. All app-config steps are at
[api.slack.com/apps](https://api.slack.com/apps).

### Part 1 — create the app 🧑

1. Go to [api.slack.com/apps](https://api.slack.com/apps), sign in, click
   **Create New App**.
2. In the dialog click **From scratch**.
3. In **App Name** type `allbert-assist`; under **Pick a workspace to develop
   your app in** choose your disposable sandbox workspace → **Create App**.
   *Expected:* the app's **Basic Information** page opens.

### Part 2 — bot token scopes 🧑

4. Left sidebar → **OAuth & Permissions**.
5. Scroll to **Scopes → Bot Token Scopes** → **Add an OAuth Scope** → add each of
   **`app_mentions:read`**, **`im:history`**, **`chat:write`** (type each, pick it
   from the list). *Expected:* all three chips show under Bot Token Scopes. (These
   are the exact set the doctor checks; missing one → `missing_bot_scopes`.)

### Part 3 — Socket Mode + app-level token 🧑

6. Left sidebar → **Socket Mode** → toggle **Enable Socket Mode** ON.
   *Expected:* a prompt may offer to create an app-level token — you can do it
   here or in the next step.
7. Left sidebar → **Basic Information** → scroll to **App-Level Tokens** → click
   **Generate Token and Scopes**.
8. In the modal: **Token Name** = `allbert-socket`; click **Add Scope** → choose
   **`connections:write`**; click **Generate**.
   *Expected:* a token starting `xapp-` is shown.
9. **Copy** the `xapp-` token into your `.env` as `ALLBERT_SLACK_APP_TOKEN` →
   **Done**. (Shown once.)

### Part 4 — event subscriptions + interactivity 🧑

10. Left sidebar → **Event Subscriptions** → toggle **Enable Events** ON.
11. Expand **Subscribe to bot events** → **Add Bot User Event** → add
    **`app_mention`**, then add **`message.im`** → **Save Changes** (bottom-right).
    *Expected:* both events listed.
12. Left sidebar → **Interactivity & Shortcuts** → toggle **Interactivity** ON →
    **Save Changes**. (With Socket Mode on, no Request URL is needed.)

### Part 5 — install + bot token 🧑

13. Left sidebar → **OAuth & Permissions** → **Install to Workspace** (or
    **Reinstall to Workspace** if you changed scopes) → review → **Allow**.
    *Expected:* you return to OAuth & Permissions with a **Bot User OAuth Token**.
14. **Copy** the **Bot User OAuth Token** (`xoxb-…`) into `.env` as
    `ALLBERT_SLACK_BOT_TOKEN`.
15. In the Slack workspace, open the test channel and run
    `/invite @allbert-assist`. *Expected:* the bot joins the channel.

### Part 6 — collect ids (easiest in a browser at app.slack.com) 🧑

16. **Team id** (`ALLBERT_SLACK_TEAM_ID`, `T…`): open Slack in a browser; copy the
    segment after `/client/` in the URL — `app.slack.com/client/`**`Txxxxxxxx`**`/…`.
17. **Channel id** (`ALLBERT_SLACK_CHANNEL_ID`, `C…`): right-click the channel in
    the sidebar → **View channel details** → scroll to the bottom → copy the
    **Channel ID**.
18. **Your member id** (`ALLBERT_SLACK_USER_ID`, `U…`): click your avatar →
    **Profile** → **⋮ (More)** → **Copy member ID**. Maps to `alice`.
19. **DM id** (`ALLBERT_SLACK_DM_CHANNEL_ID`, `D…`): click **`allbert-assist`** in
    the sidebar to open the bot DM; in the browser URL copy the
    `…/client/Txxx/`**`Dxxxxxxxx`** segment. (Used only to confirm the DM check
    landed; NOT added to the allowlist.)

### Part 7 — prepare the second (unmapped) member 🧑

20. The unmapped clicker is a **second human member of this workspace** who is
    NOT mapped to `alice`. Invite one: workspace name (top-left) → **Invite people
    to <workspace>** → send → have them accept. (Or use any existing teammate.)
    Unlike Discord, they click from their **own** Slack session, so no
    parallel-login trick is needed.
21. Capture their member id: click their name/avatar → **View full profile** →
    **⋮** → **Copy member ID** → `.env` `ALLBERT_SLACK_UNMAPPED_USER_ID`.

### Part 8 — hand off; agent wires up + smokes

22. 🧑 Tell the agent **"`.env` is ready"**.
23. 🤖 Agent runs the **Slack-only** delivery smoke
    (`mix allbert.test external-smoke -- slack`). 🧑 **Watch your channel:** the
    bot posts a parent message and a threaded reply. *Expected:* both appear;
    nothing to click. (The combined `discord_slack` selector needs Discord creds
    too; `slack` validates Slack alone.)
24. 🤖 Agent runs the **Slack-only** inbound smoke
    (`mix allbert.test external-smoke -- inbound_slack`) and tells you the **exact
    marker message**. 🧑 From your **mapped account**, in the allowlisted channel,
    send that exact text (an @mention of the bot). *Expected:* agent reports
    `socket_mode_hello` and that the runtime saw it.

### Part 9 — live channel checks (Allbert server running)

25. 🤖 Agent starts the live server and re-runs `mix allbert.channels slack
    doctor`. *Expected:* `socket_mode_status=running`; the bot shows active.
26. 🧑 **@mention.** In the allowlisted channel type `@allbert-assist`, pick the
    bot from the autocomplete, add a question, send. *Expected:* the bot replies.
    🤖 Agent confirms a `processed` Slack event for your user id.
27. 🧑 **DM.** Click **`allbert-assist`** in the sidebar (Direct Messages section)
    → send `hello allbert`. *Expected:* the bot replies. 🤖 Agent confirms a
    `processed` DM row with `chat=<your D… id>`.
28. 🧑 **Approve a confirmation (mapped).** Send a network-action prompt, e.g.
    `@allbert-assist fetch http://127.0.0.1:4052/workspace and summarize it`.
    *Expected:* the bot posts **Approve**/**Deny** buttons. Click **Approve** as
    yourself. *Expected:* the bot posts the resolved result. 🤖 Agent confirms a
    `processed` callback row and that the confirmation resolved.
29. 🧑 **Unmapped clicker is rejected.** Send a **second** network-action prompt so
    a fresh button pair appears. Have the **second (unmapped) member** click
    **Approve** from *their* Slack **before** you do. *Expected:* an ephemeral
    not-authorized response and no resolution. 🤖 Agent confirms a `rejected`
    callback row with the unmapped member's id and an unresolved confirmation.

### Part 10 — hand off; agent closes out

30. 🤖 Agent renders the **unified history**, runs final **raw-token leak scans**,
    and reports evidence paths. No operator action.

### What you actually touch, in one line

Create app (1–3) → scopes (4–5) → Socket Mode + `xapp-` token (6–9) → events +
interactivity (10–12) → install + `xoxb-` token + invite (13–15) → copy ids
(16–19) → 2nd member (20–21) → "`.env` ready" (22) → marker msg (24) → @mention
(26) → DM (27) → approve a confirmation (28) → 2nd confirmation clicked by the
unmapped member (29) → teardown (below). Everything else is the agent.

## Cleanup / teardown

After validation, tear the sandbox down so no live credential or app lingers:

1. **Disable the channel** so Allbert stops opening Socket Mode:
   `mix allbert.settings set channels.slack.enabled false`. Confirm
   `mix allbert.channels slack doctor` now reports `socket_mode_status=disabled`.
2. **Revoke the tokens.** In the app's OAuth & Permissions page, *Revoke All
   OAuth Tokens* (invalidates the `xoxb-` bot token); on Basic Information,
   delete the `xapp-` app-level token. Both are immediately dead even if a copy
   leaked.
3. **Remove the bot from the channel/workspace** (`/remove @allbert-assist`, or
   uninstall the app from the workspace under Settings → Install App).
4. **Delete the app** at [api.slack.com/apps](https://api.slack.com/apps) →
   the app → Settings → Delete App, if the sandbox is no longer needed.
5. **Discard the disposable home and its evidence:**
   `rm -rf "$ALLBERT_HOME"` (copy out `release_evidence/v052/` first if keeping
   it for the release record). Unset the `ALLBERT_SLACK_*` env vars holding raw
   tokens:
   `unset ALLBERT_SLACK_BOT_TOKEN ALLBERT_SLACK_APP_TOKEN ALLBERT_SLACK_CHANNEL_ID ALLBERT_SLACK_USER_ID`.

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
