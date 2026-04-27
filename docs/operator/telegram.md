# Telegram operator guide

Telegram is the optional remote-chat operator channel in the current v0.14.2 release. The daemon remains the source of truth: Telegram renders bounded structural status, activity, approvals, traces, adapter posture, diagnosis posture, and utility posture without reading local files directly.

Start with the [v0.14.2 operator playbook](../onboarding-and-operations.md) for the full feature-test path.

## Provider-Free Smoke

You can verify the local channel configuration path without a bot token or live Telegram message:

```bash
tmpdir=$(mktemp -d /tmp/allbert-telegram-smoke.XXXXXX)
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- daemon channels add telegram
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- daemon channels status telegram
```

This smoke proves the CLI/config/status surface works. It does not prove live polling, allowlist matching, photo download, or Telegram delivery; those require the credentialed setup below.

## Setup

Enable Telegram through the daemon channel command:

```bash
cargo run -p allbert-cli -- daemon channels add telegram
cargo run -p allbert-cli -- daemon channels status telegram
```

The channel requires a bot token and at least one allowlisted chat. Secrets stay under `~/.allbert/secrets/`; the allowlist lives under `~/.allbert/config/`.

## Commands

Telegram supports compact operator commands:

```text
/status
/activity
/trace last
/trace span <span-id>
/adapter status
/adapter approvals
/diagnose last
/utilities status
/approve <approval-id>
/reject <approval-id>
/override <reason>
/reset
```

`/status` reports the channel/runtime posture. `/activity` renders the daemon-owned `ActivitySnapshot`, including current phase, elapsed time, bounded tool summary, stuck hint, and next action when available. `/trace last` and `/trace span <span-id>` return compact, redacted structural trace summaries; prompts, responses, tool args, and tool results stay in the local session trace artifacts. `/adapter status` reports the active adapter pointer, and `/adapter approvals` lists pending adapter approvals without sending weights or diffs through Telegram. `/diagnose last` reports the latest diagnosis id, classification, confidence, and report path. `/utilities status` reports enabled utility counts and entries needing review.

## Approvals

Telegram approval prompts include the same bounded approval context as TUI, REPL, and CLI. Patch approvals may show a short diff preview, but full patch artifacts remain session-backed and install remains a separate explicit command.

Accepting an approval records review only. If a patch approval is accepted, Allbert still requires a later `self-improvement install <approval-id>` command from a local operator surface. If an adapter approval is accepted, Allbert installs the adapter but still requires explicit local activation.

Diagnosis remediation remains local-surface only. Telegram does not start `diagnose run --remediate ...`, does not enable or disable utilities, and does not run `unix_pipe`.

## Errors

Telegram turn failures append the same remediation hints as local surfaces where possible. Common examples include missing bot token, allowlist mismatch, daemon activity, provider key, cost-cap, and approval expiry guidance.

## Related Docs

- [v0.14.2 operator playbook](../onboarding-and-operations.md)
- [Telemetry operator guide](telemetry.md)
- [Tracing operator guide](tracing.md)
- [Personalization guide](personalization.md)
- [Self-diagnosis and local utilities](self-diagnosis-and-utilities.md)
- [Self-improvement guide](self-improvement.md)
- [v0.14.2 upgrade notes](../notes/v0.14.2-upgrade-2026-04-26.md)
