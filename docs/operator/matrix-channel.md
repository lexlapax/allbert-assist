# Matrix Channel Operator Guide

Status: implemented in v0.53 M6 as Channel Pack 2. This guide covers the
shipped Matrix Client-Server API surface: bearer-auth `/sync` long polling for
unencrypted text rooms, outbound `m.room.message` sends, Matrix `m.thread`
relations with rich-reply fallback, ADR 0056 inbound trust, and ADR 0057
cross-channel threading.

End-to-end encrypted rooms, media, reactions, read receipts, room creation, and
federation administration are not part of M6.

## Requirements

- A disposable Matrix account on a public/sandbox homeserver.
- A Matrix access token stored only through the channel CLI, which writes the
  token to Settings Central secrets and stores only the `secret://` reference in
  settings.
- One unencrypted room id allowlisted in `channels.matrix.allowed_room_ids`.
- One mapped Matrix user id (MXID), for example `@alice:example.org`.
- A second unmapped MXID for rejection checks when available.

The current HTTP policy denies loopback and private IP homeserver URLs. Use a
public sandbox homeserver endpoint for validation unless a later plan explicitly
adds a bounded local-homeserver policy.

## Element Setup

Use Element Web/Desktop or another Matrix client against the same public/sandbox
homeserver.

1. Create three accounts: a disposable Allbert bot account, one mapped user
   account, and one unmapped user account. In Element, click `Create Account`;
   click `Edit` beside the homeserver if you need a non-default homeserver. Save
   the full MXIDs, such as `@allbert-v053-mapped:example.org`.

   | Role | Env var | Purpose |
   | --- | --- | --- |
   | Bot account | `ALLBERT_MATRIX_BOT_USER` / `ALLBERT_MATRIX_BOT_USER_ID` | Allbert logs in, polls `/sync`, and sends replies as this account. |
   | Bot token | `ALLBERT_MATRIX_ACCESS_TOKEN` | Token owned by the bot account; never use the mapped or unmapped user's token. |
   | Mapped human | `ALLBERT_MATRIX_USER_ID` | External sender mapped to local user `alice`. |
   | Unmapped human | `ALLBERT_MATRIX_UNMAPPED_USER_ID` | External sender expected to be rejected. |
   | Room | `ALLBERT_MATRIX_ROOM_ID` | Unencrypted validation room allowlisted for the bot. |

2. From the bot or mapped account, click `+` next to the current Space name in
   the left panel, choose `New room`, and create a private room named
   `allbert-v053-validation`.
3. If Element shows `Private Rooms | Enable end-to-end encryption`, leave it
   off. Some Element Web deployments hide this control or apply
   client/homeserver defaults, so do not treat the UI as proof.
4. Invite the bot, mapped, and unmapped accounts by full MXID. Accept the invite
   in the bot and unmapped sessions.
5. Open `Room Settings` -> `Advanced` and copy the internal room id. Use the
   value that starts with `!`, not a public alias that starts with `#`.
6. After the bot has joined, prove the room is unencrypted through the Matrix
   state API. Encryption is enabled by an `m.room.encryption` state event;
   `404 M_NOT_FOUND` means the room has no encryption state and is suitable for
   v0.53.
7. For the encrypted-room rejection check, create a second private room with
   encryption intentionally on, invite/accept the bot, and do not put that room
   id in `channels.matrix.allowed_room_ids`.

Obtain the **bot account** access token from Element `Profile` ->
`All Settings` -> `Help & About` -> `Your Access Token`, or use the Matrix
password login API for the bot account only:

```sh
export ALLBERT_MATRIX_HOMESERVER_URL="https://matrix.example.org"
export ALLBERT_MATRIX_BOT_USER="@allbert-v053-bot:example.org"
read -rsp "Matrix bot password: " ALLBERT_MATRIX_BOT_PASSWORD; echo
python3 - <<'PY' >/tmp/allbert-matrix-login.json
import json, os
print(json.dumps({
  "type": "m.login.password",
  "identifier": {"type": "m.id.user", "user": os.environ["ALLBERT_MATRIX_BOT_USER"]},
  "password": os.environ["ALLBERT_MATRIX_BOT_PASSWORD"],
  "initial_device_display_name": "allbert-v053-validation"
}))
PY
curl -fsS "$ALLBERT_MATRIX_HOMESERVER_URL/_matrix/client/v3/login" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/allbert-matrix-login.json \
  >/tmp/allbert-matrix-login-response.json
export ALLBERT_MATRIX_ACCESS_TOKEN="$(python3 -c 'import json; print(json.load(open("/tmp/allbert-matrix-login-response.json"))["access_token"])')"
export ALLBERT_MATRIX_BOT_USER_ID="$(python3 -c 'import json; print(json.load(open("/tmp/allbert-matrix-login-response.json"))["user_id"])')"
rm -f /tmp/allbert-matrix-login.json /tmp/allbert-matrix-login-response.json
unset ALLBERT_MATRIX_BOT_PASSWORD
curl -fsS "$ALLBERT_MATRIX_HOMESERVER_URL/_matrix/client/v3/account/whoami" \
  -H "Authorization: Bearer $ALLBERT_MATRIX_ACCESS_TOKEN" \
  >/tmp/allbert-matrix-whoami.json
python3 -m json.tool /tmp/allbert-matrix-whoami.json
export ALLBERT_MATRIX_BOT_USER_ID="$(python3 -c 'import json; print(json.load(open("/tmp/allbert-matrix-whoami.json"))["user_id"])')"
test "$ALLBERT_MATRIX_BOT_USER_ID" = "$ALLBERT_MATRIX_BOT_USER"
```

The token has full access to the bot account. Store it only through
`mix allbert.channels matrix set-token`. If `whoami.user_id` is not the bot MXID,
you have the wrong token; do not proceed with a mapped or unmapped user's token.

Check the validation room for encryption state:

```sh
export ALLBERT_MATRIX_ROOM_ID="!room:example.org"
export ALLBERT_MATRIX_ROOM_ID_ESCAPED="$(python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["ALLBERT_MATRIX_ROOM_ID"], safe=""))')"
status="$(curl -sS -o /tmp/allbert-matrix-encryption-state.json -w "%{http_code}" \
  "$ALLBERT_MATRIX_HOMESERVER_URL/_matrix/client/v3/rooms/$ALLBERT_MATRIX_ROOM_ID_ESCAPED/state/m.room.encryption/" \
  -H "Authorization: Bearer $ALLBERT_MATRIX_ACCESS_TOKEN")"
case "$status" in
  404) echo "PASS: Matrix room has no m.room.encryption state" ;;
  200) echo "FAIL: Matrix room is encrypted; create a new unencrypted room"; python3 -m json.tool /tmp/allbert-matrix-encryption-state.json; false ;;
  *) echo "FAIL: unexpected Matrix encryption-state status $status"; cat /tmp/allbert-matrix-encryption-state.json; false ;;
esac
```

If Element Web creates an encrypted private room and exposes no encryption
control, create the validation room through the Matrix API without an
`m.room.encryption` initial state:

```sh
python3 - <<'PY' >/tmp/allbert-matrix-create-room.json
import json, os
print(json.dumps({
  "visibility": "private",
  "preset": "private_chat",
  "name": "allbert-v053-validation",
  "topic": "Allbert v0.53 Matrix validation",
  "invite": [
    os.environ["ALLBERT_MATRIX_USER_ID"],
    os.environ["ALLBERT_MATRIX_UNMAPPED_USER_ID"]
  ],
  "initial_state": [
    {
      "type": "m.room.history_visibility",
      "state_key": "",
      "content": {"history_visibility": "joined"}
    }
  ]
}))
PY
curl -fsS "$ALLBERT_MATRIX_HOMESERVER_URL/_matrix/client/v3/createRoom" \
  -H "Authorization: Bearer $ALLBERT_MATRIX_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/allbert-matrix-create-room.json \
  >/tmp/allbert-matrix-create-room-response.json
export ALLBERT_MATRIX_ROOM_ID="$(python3 -c 'import json; print(json.load(open("/tmp/allbert-matrix-create-room-response.json"))["room_id"])')"
rm -f /tmp/allbert-matrix-create-room.json /tmp/allbert-matrix-create-room-response.json
echo "$ALLBERT_MATRIX_ROOM_ID"
```

Have the mapped/unmapped accounts accept the invites, send one seed message, and
re-run the encryption-state check. If the API-created room still has
`m.room.encryption`, the homeserver/client policy is not suitable for v0.53
validation; use a sandbox homeserver that allows unencrypted rooms.

## Configure

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-matrix.XXXXXX)"
mix ecto.migrate.allbert --quiet

mix allbert.settings set channels.matrix.homeserver_url "$ALLBERT_MATRIX_HOMESERVER_URL"
# This stores the bot account token. It must be for ALLBERT_MATRIX_BOT_USER,
# not for ALLBERT_MATRIX_USER_ID or ALLBERT_MATRIX_UNMAPPED_USER_ID.
mix allbert.channels matrix set-token "$ALLBERT_MATRIX_ACCESS_TOKEN"
mix allbert.settings set channels.matrix.allowed_room_ids '["'"$ALLBERT_MATRIX_ROOM_ID"'"]'
# This maps the mapped human MXID to local user alice. No human token is used.
mix allbert.channels matrix map --external-user "$ALLBERT_MATRIX_USER_ID" --user alice
mix allbert.settings set channels.matrix.enabled true
mix allbert.settings get channels.matrix.sync_timeout_ms
mix allbert.settings get channels.matrix.sync_timeline_limit
```

The settings output must show `channels.matrix.access_token_ref` as a
`secret://` value and must not print the raw access token. The polling defaults
should report `channels.matrix.sync_timeout_ms=30000` and
`channels.matrix.sync_timeline_limit=50`. Do not set `sync_timeout_ms=0` for
normal validation; Allbert keeps the HTTP receive timeout above the Matrix
long-poll timeout internally. For short-lived operator `poll-once` runs, Allbert
also catches up through latest Matrix `/rooms/{roomId}/messages` history without
a `from` token when a cold `/sync` returns only already-seen events.

## Verify

Run the deterministic local gate first:

```sh
MIX_ENV=test mix allbert.test release.v053
```

Run the redacted doctor:

```sh
mix allbert.channels setup-check matrix
mix allbert.channels matrix doctor
mix allbert.channels show matrix
```

`setup-check` reports redacted Settings Central readiness, missing fields, the
independent Matrix smoke command, and the no-automatic-provider-retry posture.
The doctor calls `GET /_matrix/client/v3/account/whoami`, reports redacted
credential/endpoint state, and includes local poller status (`running`,
`disabled`, `not_started`, `error`, or `unavailable`).

Run the Matrix smoke independently. This command must not require Telegram,
email, Discord, Slack, WhatsApp, or Signal env:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_MATRIX_HOMESERVER_URL="https://matrix.example.org"
export ALLBERT_MATRIX_ACCESS_TOKEN="..."
export ALLBERT_MATRIX_ROOM_ID="!room:example.org"
mix allbert.test external-smoke -- matrix
```

It calls `/account/whoami`, sends a real `m.room.message` into the configured
unencrypted room, records a `ChannelThread` outbound ref, asserts echo
suppression, and writes
`<ALLBERT_HOME>/release_evidence/v053/external-smoke-matrix-<ts>.json`.

The inbound `/sync` path has its own interactive smoke (parity with
`inbound_telegram`). It also needs `ALLBERT_MATRIX_USER_ID` (the mapped MXID).
The task streams its marker prompt live; when it prints a marker, send the exact
`<marker> matrix` line from that MXID in the allowlisted room:

```sh
export ALLBERT_MATRIX_USER_ID="@mapped:example.org"
export ALLBERT_MATRIX_INBOUND_TIMEOUT_MS=600000
mix allbert.test external-smoke -- inbound_matrix
```

It starts the adapter, which auto-polls `/sync` with a bounded message timeline
filter and the same `/messages` catch-up used by `poll-once`. The smoke keys on
the printed marker, routes that mapped message to the runtime, and writes
`<ALLBERT_HOME>/release_evidence/v053/external-smoke-inbound-matrix-<ts>.json`.
Any bounded recent room history returned by `since=nil` is provider backlog, not
release evidence.

Manual validation before tag:

- Start Allbert normally with the configured `ALLBERT_HOME`.
- Send a text `m.room.message` from the mapped MXID in the allowlisted room and
  confirm a runtime request is created. If `poll-once` reports only duplicates
  and/or non-actionable rejections such as Matrix state events or bot echoes,
  send one new mapped message and run `poll-once` again; do not clear or redact
  the room to make validation pass.
- Send from an unmapped MXID and confirm the request is rejected before runtime.
- Trigger a note-write confirmation from the mapped MXID:
  `create a note titled matrixapproval with body hi`; run
  `mix allbert.channels matrix poll-once`; capture the pending confirmation id
  from `mix allbert.confirmations list`.
- From the mapped MXID, send `ALLBERT:APPROVE:<confirmation_id>` in the same
  room; run `mix allbert.channels matrix poll-once`; confirm the bot replies and
  `mix allbert.confirmations list --resolved` shows the confirmation approved.
  Element may render reply/fallback text with a display-name prefix such as
  `Lex Lapax:ALLBERT:APPROVE:<confirmation_id>`; Matrix normalizes that bounded
  fallback before callback handling, but the safest operator action is still to
  send the exact command as a plain room message.
- Trigger a second note-write confirmation, then send
  `ALLBERT:APPROVE:<confirmation_id>` from the unmapped MXID. After
  `mix allbert.channels matrix poll-once`, the confirmation must still be
  pending. Clean it up from the mapped MXID with
  `ALLBERT:DENY:<confirmation_id>`.
- Confirm outbound replies include `m.relates_to.rel_type = m.thread`,
  `event_id` for the thread root, and `m.in_reply_to` fallback metadata.
- Send or observe an encrypted room event and confirm it is rejected/unsupported
  rather than decrypted or treated as runtime input.
- Inspect recent Matrix rows when a check is ambiguous:

  ```sh
  export DATABASE_PATH="${DATABASE_PATH:-$ALLBERT_HOME/db/allbert_manual.db}"
  sqlite3 -header -column "$DATABASE_PATH" \
  "select id, inserted_at, direction, status, external_user_id, user_id, thread_id, reason, payload_summary
   from channel_events
   where channel='matrix'
   order by inserted_at desc
   limit 16;"
  ```

- Run `rg -i 'access_token|token|password|secret|\+[0-9]{6,}' "$ALLBERT_HOME" || true`
  and resolve any raw-token or phone-number hits before release.

## Cleanup

Revoke or rotate the Matrix access token, leave/delete the disposable room as
appropriate for the homeserver, disable the Matrix channel in the validation
home, and keep the release-evidence JSON files for closeout.
