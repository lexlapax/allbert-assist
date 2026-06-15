# Signal Channel Operator Guide

Status: implemented in v0.53 M8 as Channel Pack 2. This guide covers the
shipped Signal surface: `signal-cli` JSON-RPC daemon integration, local control
endpoint checks, Allbert Home key custody permissions, ACI-keyed identity,
reply-chain quote-by-timestamp delivery, ADR 0056 inbound trust, and ADR 0059
`:e2ee_origin` trust-class stamping.

Signal account registration, contact discovery, groups, attachments, reactions,
and non-daemon transports are not part of M8.

## Requirements

- A Signal account already linked to `signal-cli`.
- `signal-cli` installed on the host.
- Signal account data under `<ALLBERT_HOME>/signal/`; directory mode must be
  `0700`, key/config files must be `0600`.
- Preferred control mode: a local UNIX socket under Allbert Home with `0600`
  permissions. Loopback HTTP is allowed only when explicitly configured with
  local auth/ACL controls.
- One mapped sender ACI UUID and one unmapped ACI UUID for rejection checks.

Signal identity links use ACI UUIDs, not phone numbers. Phone numbers may be
needed by `signal-cli` for account setup or delivery, but Allbert channel events,
thread refs, traces, doctor output, and release evidence must not expose raw
phone numbers.

## Configure

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-signal.XXXXXX)"
mix ecto.migrate.allbert --quiet

mix allbert.settings set channels.signal.account_identifier "$ALLBERT_SIGNAL_ACCOUNT"
mix allbert.settings set channels.signal.local_aci "$ALLBERT_SIGNAL_LOCAL_ACI"
mix allbert.settings set channels.signal.data_dir "$ALLBERT_HOME/signal"
mix allbert.settings set channels.signal.control_mode socket
mix allbert.settings set channels.signal.socket_path "$ALLBERT_HOME/signal/signal-cli.sock"
mix allbert.channels signal map --aci "$ALLBERT_SIGNAL_MAPPED_ACI" --user alice
mix allbert.settings set channels.signal.enabled true
```

For an HTTP daemon/proxy smoke, configure loopback HTTP explicitly and store the
auth token as a Settings Central secret:

```sh
ALLBERT_SIGNAL_CONTROL_AUTH="$ALLBERT_SIGNAL_CONTROL_AUTH" \
  mix run --no-start -e 'AllbertAssist.Settings.Secrets.put_secret("secret://channels/signal/control_auth", System.fetch_env!("ALLBERT_SIGNAL_CONTROL_AUTH"), %{actor: "operator", channel: :cli})'

mix allbert.settings set channels.signal.control_mode loopback_http
mix allbert.settings set channels.signal.loopback_http_base_url "$ALLBERT_SIGNAL_CONTROL_HTTP_BASE_URL"
```

## Verify

Run the deterministic local gate first:

```sh
MIX_ENV=test mix allbert.test release.v053
```

Run the redacted doctor:

```sh
mix allbert.channels setup-check signal
mix allbert.channels signal doctor
mix allbert.channels show signal
```

`setup-check` reports redacted Settings Central readiness, missing fields, the
independent Signal smoke command, the `signal link` pairing command, and the
no-automatic-provider-retry posture. The doctor enforces the Allbert Home data
directory, reports local-only control state, checks socket/key-file permissions
when present, writes a redacted state envelope under the Allbert cache root, and
must not print the account phone number or any control auth secret.

Run the Signal smoke independently. This command must not require Telegram,
email, Matrix, WhatsApp, Discord, or Slack env:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_SIGNAL_ACCOUNT="+15551234567"
export ALLBERT_SIGNAL_RECIPIENT="2f8f8f44-8f1a-4db3-a56a-8e0612f6f001"
export ALLBERT_SIGNAL_CONTROL_HTTP_BASE_URL="http://127.0.0.1:8080"
export ALLBERT_SIGNAL_CONTROL_AUTH="..."
mix allbert.test external-smoke -- signal
```

It calls the configured loopback JSON-RPC endpoint, sends one real Signal text
message through `signal-cli`, and writes
`<ALLBERT_HOME>/release_evidence/v053/external-smoke-signal-<ts>.json`.

Manual validation before tag:

- Start Allbert normally with the configured `ALLBERT_HOME` and `signal-cli`
  daemon.
- Send a text message from the mapped ACI and confirm the daemon notification
  reaches the Signal adapter, creates a channel event, resolves the mapped user,
  submits to runtime, and records `trust_class = e2ee_origin`.
- Send from an unmapped ACI and confirm the event is rejected before runtime.
- Confirm outbound replies quote the inbound Signal timestamp/author rather than
  an opaque provider id.
- Confirm default unified cross-channel views do not expose Signal
  `:e2ee_origin` content from a different channel unless explicitly opted in.
- Run `rg -i 'access_token|token|password|secret|\+[0-9]{6,}' "$ALLBERT_HOME" || true`
  and resolve any raw-token or phone-number hits before release.

## Cleanup

Disable the Signal channel in the validation home, stop the `signal-cli` daemon
or loopback proxy, revoke/rotate any temporary local auth token, and keep the
release-evidence JSON files for closeout.
