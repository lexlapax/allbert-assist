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

## Configure

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-matrix.XXXXXX)"
mix ecto.migrate.allbert --quiet

mix allbert.settings set channels.matrix.homeserver_url "$ALLBERT_MATRIX_HOMESERVER_URL"
mix allbert.channels matrix set-token "$ALLBERT_MATRIX_ACCESS_TOKEN"
mix allbert.settings set channels.matrix.allowed_room_ids '["'"$ALLBERT_MATRIX_ROOM_ID"'"]'
mix allbert.channels matrix map --external-user "$ALLBERT_MATRIX_USER_ID" --user alice
mix allbert.settings set channels.matrix.enabled true
```

The settings output must show `channels.matrix.access_token_ref` as a
`secret://` value and must not print the raw access token.

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

Manual validation before tag:

- Start Allbert normally with the configured `ALLBERT_HOME`.
- Send a text `m.room.message` from the mapped MXID in the allowlisted room and
  confirm a runtime request is created.
- Send from an unmapped MXID and confirm the request is rejected before runtime.
- Confirm outbound replies include `m.relates_to.rel_type = m.thread`,
  `event_id` for the thread root, and `m.in_reply_to` fallback metadata.
- Send or observe an encrypted room event and confirm it is rejected/unsupported
  rather than decrypted or treated as runtime input.
- Run `rg -i 'access_token|token|password|secret|\+[0-9]{6,}' "$ALLBERT_HOME" || true`
  and resolve any raw-token or phone-number hits before release.

## Cleanup

Revoke or rotate the Matrix access token, leave/delete the disposable room as
appropriate for the homeserver, disable the Matrix channel in the validation
home, and keep the release-evidence JSON files for closeout.
