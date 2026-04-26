# Telegram operator guide

v0.12.1 made the Telegram pilot more channel-native while keeping the daemon and kernel as the source of truth. v0.12.2 adds structural trace summaries without sending full local trace content back through Telegram. v0.13 adds structural adapter status and adapter-approval listing.

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
/approve <approval-id>
/reject <approval-id>
/override <reason>
/reset
```

`/status` reports the channel/runtime posture. `/activity` renders the daemon-owned `ActivitySnapshot`, including current phase, elapsed time, bounded tool summary, stuck hint, and next action when available. `/trace last` and `/trace span <span-id>` return compact, redacted structural trace summaries; prompts, responses, tool args, and tool results stay in the local session trace artifacts. `/adapter status` reports the active adapter pointer, and `/adapter approvals` lists pending adapter approvals without sending weights or diffs through Telegram.

## Approvals

Telegram approval prompts include the same bounded approval context as TUI, REPL, and CLI. Patch approvals may show a short diff preview, but full patch artifacts remain session-backed and install remains a separate explicit command.

Accepting an approval records review only. If a patch approval is accepted, Allbert still requires a later `self-improvement install <approval-id>` command from a local operator surface. If an adapter approval is accepted, Allbert installs the adapter but still requires explicit local activation.

## Errors

Telegram turn failures append the same remediation hints as local surfaces where possible. Common examples include missing bot token, allowlist mismatch, daemon activity, provider key, cost-cap, and approval expiry guidance.

## Related Docs

- [Telemetry operator guide](telemetry.md)
- [Tracing operator guide](tracing.md)
- [Personalization guide](personalization.md)
- [Self-improvement guide](self-improvement.md)
- [v0.13 upgrade notes](../notes/v0.13-upgrade-2026-04-26.md)
