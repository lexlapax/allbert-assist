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

## signal-cli Setup

Install a current `signal-cli` release and confirm the version before
validation. Upstream warns that stale releases can stop working after Signal
server changes.

```sh
export ALLBERT_HOME="${ALLBERT_HOME:-$(mktemp -d /tmp/allbert-signal.XXXXXX)}"
export ALLBERT_SIGNAL_ACCOUNT="+15551234567"
mkdir -p "$ALLBERT_HOME/signal"
chmod 700 "$ALLBERT_HOME/signal"
signal-cli --version
```

Link the Allbert bot account as a secondary device when possible:

```sh
signal-cli --config "$ALLBERT_HOME/signal" link -n allbert-v053
```

Expected: `signal-cli` prints an `sgnl://linkdevice?...` URI. In the primary
Signal mobile app for the disposable bot account, open `Settings` -> `Linked
devices` -> `Link New Device` and scan a QR code for that URI. If `qrencode` is
available:

```sh
export ALLBERT_SIGNAL_LINK_URI="sgnl://linkdevice?uuid=<from-signal-cli>&pub_key=<from-signal-cli>"
qrencode -t ANSIUTF8 "$ALLBERT_SIGNAL_LINK_URI"
```

If registering a disposable number directly instead:

```sh
signal-cli --config "$ALLBERT_HOME/signal" -a "$ALLBERT_SIGNAL_ACCOUNT" register
signal-cli --config "$ALLBERT_HOME/signal" -a "$ALLBERT_SIGNAL_ACCOUNT" verify "<sms-or-voice-code>"
```

If registration asks for a CAPTCHA token, use upstream's Signal CAPTCHA flow and
repeat `register --captcha <signalcaptcha://...>`.

Discover mapped/unmapped ACI UUIDs. If the sender phone numbers are known and
have exchanged at least one message with the bot, `listContacts` can print UUIDs:

```sh
export ALLBERT_SIGNAL_MAPPED_PHONE="+15550001111"
export ALLBERT_SIGNAL_UNMAPPED_PHONE="+15550002222"
signal-cli --config "$ALLBERT_HOME/signal" -a "$ALLBERT_SIGNAL_ACCOUNT" \
  -o json listContacts --all-recipients --detailed --internal \
  "$ALLBERT_SIGNAL_MAPPED_PHONE" "$ALLBERT_SIGNAL_UNMAPPED_PHONE" \
  >/tmp/allbert-v053-signal-contacts.json
python3 - <<'PY'
import json
data = json.load(open("/tmp/allbert-v053-signal-contacts.json"))
for row in data:
  print(row.get("number"), row.get("uuid"))
PY
```

Provider-authoritative fallback: run the JSON-RPC HTTP daemon, send one message
from each sender to the bot, and extract `sourceUuid` from receive
notifications. `sourceUuid` is the field Allbert maps.

```sh
signal-cli --config "$ALLBERT_HOME/signal" --scrub-log -a "$ALLBERT_SIGNAL_ACCOUNT" \
  daemon --http 127.0.0.1:8080 >/tmp/allbert-v053-signal-http.log 2>&1 &
export V053_SIGNAL_DAEMON_PID=$!
export ALLBERT_SIGNAL_CONTROL_HTTP_BASE_URL="http://127.0.0.1:8080"
curl -fsS "$ALLBERT_SIGNAL_CONTROL_HTTP_BASE_URL/api/v1/check"
curl -Ns "$ALLBERT_SIGNAL_CONTROL_HTTP_BASE_URL/api/v1/events" \
  >/tmp/allbert-v053-signal-events.sse &
export V053_SIGNAL_EVENTS_PID=$!
```

Send `v053 signal mapped aci capture` from the mapped sender and
`v053 signal unmapped aci capture` from the unmapped sender. Then extract the
observed UUIDs:

```sh
python3 - <<'PY'
import json
for line in open("/tmp/allbert-v053-signal-events.sse"):
  line = line.strip()
  if not line.startswith("data:"):
    continue
  payload = json.loads(line[5:].strip())
  envelope = payload.get("params", {}).get("envelope", {})
  text = envelope.get("dataMessage", {}).get("message")
  uuid = envelope.get("sourceUuid")
  if uuid and text:
    print(f"{text}: {uuid}")
PY
```

Stop the temporary discovery daemon if you will use socket mode:

```sh
kill "$V053_SIGNAL_EVENTS_PID" "$V053_SIGNAL_DAEMON_PID"
```

Preferred manual validation control is a UNIX socket under Allbert Home:

```sh
export ALLBERT_SIGNAL_SOCKET_PATH="$ALLBERT_HOME/signal/signal-cli.sock"
signal-cli --config "$ALLBERT_HOME/signal" --scrub-log -a "$ALLBERT_SIGNAL_ACCOUNT" \
  daemon --socket "$ALLBERT_SIGNAL_SOCKET_PATH" >/tmp/allbert-v053-signal-socket.log 2>&1 &
export V053_SIGNAL_DAEMON_PID=$!
```

The external smoke uses loopback HTTP:

```sh
signal-cli --config "$ALLBERT_HOME/signal" --scrub-log -a "$ALLBERT_SIGNAL_ACCOUNT" \
  daemon --http 127.0.0.1:8080 >/tmp/allbert-v053-signal-http.log 2>&1 &
export V053_SIGNAL_DAEMON_PID=$!
export ALLBERT_SIGNAL_CONTROL_HTTP_BASE_URL="http://127.0.0.1:8080"
export ALLBERT_SIGNAL_CONTROL_AUTH="$(openssl rand -hex 24)"
```

`signal-cli`'s loopback HTTP endpoint does not require this auth token; Allbert
requires it in Settings Central so loopback control is explicit and auditable.
Use OS loopback/firewall controls or a local authenticated proxy when local
multi-user isolation matters.

## Configure

```sh
export ALLBERT_HOME="${ALLBERT_HOME:-$(mktemp -d /tmp/allbert-signal.XXXXXX)}"
mix ecto.migrate.allbert --quiet

export ALLBERT_SIGNAL_LOCAL_ACI="<bot-account-aci-uuid>"
export ALLBERT_SIGNAL_MAPPED_ACI="<mapped-sourceUuid>"
export ALLBERT_SIGNAL_UNMAPPED_ACI="<unmapped-sourceUuid>"
export ALLBERT_SIGNAL_RECIPIENT="$ALLBERT_SIGNAL_MAPPED_ACI"

# Use the bot account's own ACI when your signal-cli build or account tooling
# exposes it. If it is not exposed directly, record the source used for this
# value in validation notes; mapped/unmapped authorization is enforced against
# inbound sourceUuid.
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
export ALLBERT_SIGNAL_CONTROL_AUTH="${ALLBERT_SIGNAL_CONTROL_AUTH:-$(openssl rand -hex 24)}"
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
# If you started the socket daemon for manual validation, stop it and start the
# loopback-HTTP daemon variant from the setup section before this smoke.
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
