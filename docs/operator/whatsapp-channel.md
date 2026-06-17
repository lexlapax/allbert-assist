# WhatsApp Channel Operator Guide

Status: implemented in v0.53 M7 as Channel Pack 2. This guide covers the
shipped WhatsApp Cloud API surface: signed webhook ingress from M4, text
outbound delivery through Graph API, in-session interactive approval buttons,
reply-chain quote metadata with 24h TTL degradation, ADR 0056 inbound trust, and
ADR 0057 cross-channel threading.

Media messages, template-message initiation outside WhatsApp's customer-care
window, reactions, catalog flows, payments, and multi-number WABA management are
not part of M7.

## Requirements

- A Meta WhatsApp Cloud API test or sandbox number.
- A Cloud API access token stored through `mix allbert.channels whatsapp
  set-token`.
- The WABA id and `phone_number_id` for the business number.
- A public HTTPS webhook URL, commonly through a short-lived validation tunnel.
- App secret and webhook verify token stored as Settings Central secrets.
- One mapped sender phone number and one unmapped sender for rejection checks.

Phone numbers must be treated as personal data. CLI, doctor, event, thread, and
release-evidence output must not expose raw phone numbers or tokens.

## Configure

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-whatsapp.XXXXXX)"
mix ecto.migrate.allbert --quiet

mix allbert.channels whatsapp set-token "$ALLBERT_WHATSAPP_ACCESS_TOKEN"
mix allbert.settings set channels.whatsapp.phone_number_id "$ALLBERT_WHATSAPP_PHONE_NUMBER_ID"
mix allbert.settings set channels.whatsapp.waba_id "$ALLBERT_WHATSAPP_WABA_ID"
mix allbert.channels whatsapp map --external-user "$ALLBERT_WHATSAPP_MAPPED_PHONE" --user alice

ALLBERT_WHATSAPP_APP_SECRET="$ALLBERT_WHATSAPP_APP_SECRET" \
  mix run --no-start -e 'AllbertAssist.Settings.Secrets.put_secret("secret://channels/whatsapp/app_secret", System.fetch_env!("ALLBERT_WHATSAPP_APP_SECRET"), %{actor: "operator", channel: :cli})'

ALLBERT_WHATSAPP_WEBHOOK_VERIFY_TOKEN="$ALLBERT_WHATSAPP_WEBHOOK_VERIFY_TOKEN" \
  mix run --no-start -e 'AllbertAssist.Settings.Secrets.put_secret("secret://channels/whatsapp/webhook_verify_token", System.fetch_env!("ALLBERT_WHATSAPP_WEBHOOK_VERIFY_TOKEN"), %{actor: "operator", channel: :cli})'

mix allbert.settings set channels.whatsapp.webhook_enabled true
mix allbert.settings set channels.whatsapp.enabled true
```

Register the webhook URL in Meta as:

```text
https://<public-host>/webhooks/whatsapp/<ALLBERT_WHATSAPP_PHONE_NUMBER_ID>
```

The verify token must match `secret://channels/whatsapp/webhook_verify_token`.
The POST signature is verified before JSON parsing with the configured
`secret://channels/whatsapp/app_secret`.

## Verify

Run the deterministic local gate first:

```sh
MIX_ENV=test mix allbert.test release.v053
```

Run the redacted doctor:

```sh
mix allbert.channels setup-check whatsapp
mix allbert.channels whatsapp doctor
mix allbert.channels show whatsapp
```

`setup-check` reports redacted Settings Central readiness, missing fields, the
independent WhatsApp smoke command, and the no-automatic-provider-retry posture.
The doctor calls Graph API phone metadata, reports auth/endpoint state and local
adapter status, writes a redacted state envelope under the Allbert cache root,
and must not print the raw access token or phone number.

Run the WhatsApp smoke independently. This command must not require Telegram,
email, Matrix, Discord, Slack, or Signal env:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_WHATSAPP_ACCESS_TOKEN="..."
export ALLBERT_WHATSAPP_PHONE_NUMBER_ID="15551234567"
export ALLBERT_WHATSAPP_TO_PHONE="+15550001111"
mix allbert.test external-smoke -- whatsapp
```

It calls Graph API phone metadata, sends one real text message through
`/<phone_number_id>/messages`, and writes
`<ALLBERT_HOME>/release_evidence/v053/external-smoke-whatsapp-<ts>.json`.

Manual validation before tag:

- Start Allbert normally with the configured `ALLBERT_HOME` and public webhook
  URL.
- Validate the signed-webhook auth path locally (no Meta/tunnel required) against
  a running `mix phx.server`. `whatsapp post-webhook` computes the same
  `X-Hub-Signature-256` HMAC the ingress checks and issues a real HTTP POST;
  `--bad-signature` confirms the pre-parse 401 denial. (`whatsapp simulate` injects
  in-process and bypasses this auth — it is routing-only, not signature evidence.)

  ```sh
  mix allbert.channels whatsapp post-webhook --url http://127.0.0.1:4000 \
    --from "$ALLBERT_WHATSAPP_TO_PHONE" "whatsapp inbound auth check"        # → HTTP 200
  mix allbert.channels whatsapp post-webhook --url http://127.0.0.1:4000 --bad-signature \
    --from "$ALLBERT_WHATSAPP_TO_PHONE" "whatsapp deny check"               # → HTTP 401
  ```

- Send a text message from the mapped phone number and confirm the M4 signed
  webhook reaches the WhatsApp adapter, creates a channel event, resolves the
  mapped user, and submits to runtime.
- Send from the unmapped phone number and confirm the event is rejected before
  runtime.
- Trigger a confirmation and verify WhatsApp renders in-session buttons. Click
  approve, deny, and show in separate pending confirmations and confirm callback
  scope is rechecked before the confirmation action runs.
- Verify a fresh inbound message gets an outbound `context.message_id` reply.
  Repeat with a fixture or delayed event outside the 24h quote TTL and confirm
  the adapter degrades to a flat outbound text without `context`.
- Run `rg -i 'access_token|token|password|secret|\+[0-9]{6,}' "$ALLBERT_HOME" || true`
  and resolve any raw-token or phone-number hits before release.

## Cleanup

Disable the channel in the validation home, remove the webhook callback from the
Meta app, revoke or rotate the temporary access token, stop any tunnel, and keep
the release-evidence JSON files for closeout.
