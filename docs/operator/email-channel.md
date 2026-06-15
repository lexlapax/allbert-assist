# Email Channel Operator Guide

Status: implemented in v0.53 M5 as Channel Pack 1 retro-validation. This guide
covers the shipped email surface: SMTP outbound delivery, IMAP inbound polling,
ADR 0016 typed-command approvals, ADR 0056 inbound trust, and ADR 0057
cross-channel threading.

## Requirements

- A disposable mailbox with SMTP and IMAP enabled, reachable with
  **password / app-password auth**. The channel speaks IMAP `LOGIN` and SMTP
  `AUTH` — it does **not** implement OAuth2 / XOAUTH2, so OAuth-only mailboxes
  (modern Gmail/Microsoft, where basic IMAP/SMTP passwords are disabled) are out
  of scope; XOAUTH2 support is a future milestone.
- Separate IMAP and SMTP passwords or app passwords when the provider supports
  them.
- One mapped sender address and one unmapped sender address for rejection
  checks.
- A disposable `ALLBERT_HOME` for release validation.

The v0.53 live validation used **AgentMail** (`https://agentmail.to`), an
API-first inbox with standard IMAP/SMTP where the inbox address is the username
and the API key is the password: IMAP `imap.agentmail.to:993` (SSL), SMTP
`smtp.agentmail.to:587` (STARTTLS — use 587, not the implicit-TLS 465 port), and
the SMTP `From` must equal the inbox address. Any provider that still allows
password/app-password IMAP+SMTP (Fastmail, Proton Bridge, Zoho, a self-hosted
server) works the same way.

The v0.53 parser decodes MIME encoded-word headers plus base64 and
quoted-printable text bodies. This is mandatory for real mailbox validation
because provider mail commonly arrives encoded even when the visible message is
plain text.

## Configure

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-email.XXXXXX)"
mix ecto.migrate.allbert --quiet

mix allbert.settings set channels.email.enabled true
mix allbert.settings set channels.email.imap_host "$ALLBERT_EMAIL_IMAP_HOST"
mix allbert.settings set channels.email.imap_port "$ALLBERT_EMAIL_IMAP_PORT"
mix allbert.settings set channels.email.imap_ssl true
mix allbert.settings set channels.email.imap_username "$ALLBERT_EMAIL_IMAP_USERNAME"
mix allbert.channels email set-password --type imap "$ALLBERT_EMAIL_IMAP_PASSWORD"
mix allbert.settings set channels.email.imap_mailbox "${ALLBERT_EMAIL_IMAP_MAILBOX:-INBOX}"
mix allbert.settings set channels.email.smtp_host "$ALLBERT_EMAIL_SMTP_HOST"
mix allbert.settings set channels.email.smtp_port "$ALLBERT_EMAIL_SMTP_PORT"
mix allbert.settings set channels.email.smtp_tls true
mix allbert.settings set channels.email.smtp_username "$ALLBERT_EMAIL_SMTP_USERNAME"
mix allbert.channels email set-password --type smtp "$ALLBERT_EMAIL_SMTP_PASSWORD"
mix allbert.settings set channels.email.from_address "$ALLBERT_EMAIL_FROM_ADDRESS"
mix allbert.channels email map --external-user "$ALLBERT_EMAIL_MAPPED_SENDER" --user alice
```

Settings output must show IMAP/SMTP password refs as `secret://` values and must
not print raw passwords.

## Verify

Run the deterministic local gate first:

```sh
MIX_ENV=test mix allbert.test release.v053
```

Run the redacted doctor:

```sh
mix allbert.channels email doctor
mix allbert.channels show email
```

The doctor probes IMAP login/mailbox access through the configured client,
reports SMTP credential configuration, includes local poller status, and writes
a redacted state envelope under the Allbert cache root.

Run the outbound smoke independently. This command must not require Telegram
env:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_EMAIL_SMTP_HOST="..."
export ALLBERT_EMAIL_SMTP_PORT="587"
export ALLBERT_EMAIL_SMTP_USERNAME="..."
export ALLBERT_EMAIL_SMTP_PASSWORD="..."
export ALLBERT_EMAIL_FROM_ADDRESS="allbert@example.test"
export ALLBERT_EMAIL_TO_ADDRESS="operator@example.test"
mix allbert.test external-smoke -- email
```

It sends a real SMTP parent message and reply, records `ChannelThread` outbound
refs, asserts echo-suppression metadata, and writes
`<ALLBERT_HOME>/release_evidence/v053/external-smoke-email-<ts>.json`.

Run the inbound smoke independently. This command must not require Telegram env:

```sh
export ALLBERT_TEST_KEEP_TMP=1
export ALLBERT_EMAIL_INBOUND_TIMEOUT_MS=600000
export ALLBERT_SMOKE_MARKER="allbert-v053-email-check"
export ALLBERT_EMAIL_IMAP_HOST="..."
export ALLBERT_EMAIL_IMAP_PORT="993"
export ALLBERT_EMAIL_IMAP_USERNAME="..."
export ALLBERT_EMAIL_IMAP_PASSWORD="..."
export ALLBERT_EMAIL_SMTP_HOST="..."
export ALLBERT_EMAIL_SMTP_PORT="587"
export ALLBERT_EMAIL_SMTP_USERNAME="..."
export ALLBERT_EMAIL_SMTP_PASSWORD="..."
export ALLBERT_EMAIL_FROM_ADDRESS="allbert@example.test"
export ALLBERT_EMAIL_MAPPED_SENDER="operator@example.test"
mix allbert.test external-smoke -- inbound_email
```

It starts the real IMAP adapter, waits for a marker email from the mapped sender
to reach `Runtime.submit_user_input/1`, and writes
`<ALLBERT_HOME>/release_evidence/v053/external-smoke-inbound-email-<ts>.json`.

Manual validation before tag:

- Start Allbert normally with the configured `ALLBERT_HOME`.
- Send plain text and MIME-encoded messages from the mapped sender and confirm
  runtime requests are created with decoded text.
- Send from the unmapped sender and confirm the request is rejected before
  runtime.
- Trigger an email confirmation and verify `APPROVE:<confirmation_id>`,
  `DENY:<confirmation_id>`, and `SHOW:<confirmation_id>` typed commands are
  detected before quoted reply text.
- Confirm outbound replies contain `Date`, `Message-ID`, `In-Reply-To`,
  `References`, `MIME-Version`, and `Content-Transfer-Encoding` headers.
- Run `rg -i 'token|password|secret|\+[0-9]{6,}' "$ALLBERT_HOME" || true` and
  resolve any raw-password or phone-number hits before release.

## Cleanup

Delete or disable the disposable mailbox/app passwords, disable the email
channel in the validation home, delete test messages when practical, and keep
the release-evidence JSON files for closeout.
