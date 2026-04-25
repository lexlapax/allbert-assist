# Telemetry operator guide

v0.11 makes session telemetry a daemon protocol surface. The TUI, classic REPL, CLI, and future frontends all read the same kernel-owned `TelemetrySnapshot`.

## Commands

Use `/status` for the concise backward-compatible view:

```text
/status
```

Use `/telemetry` for the richer live snapshot:

```text
/telemetry
```

Use CLI JSON for scripts and release smokes:

```bash
cargo run -p allbert-cli -- telemetry --json
```

## Snapshot Fields

`TelemetrySnapshot` includes:

- session id and channel
- provider, model id, API-key posture, max output tokens, and configured context window
- latest response token usage and cumulative session token usage
- context usage percentage when `model.context_window_tokens > 0`; otherwise context renders as unknown
- session cost, today's cost, and current turn budget
- memory synopsis bytes, ephemeral bytes, durable count, staged count, episode count, fact count, staged-this-turn count, and prefetch-hit count
- active skills, always-eligible memory skills, last agent stack, and last resolved intent
- pending inbox count and trace state
- setup version

Token and context values are provider-reported from the latest model response. v0.11 does not estimate preflight context pressure with a tokenizer.

## Status-Line Catalog

The TUI status line is a selected view over telemetry:

| Item | Meaning |
| --- | --- |
| `model` | provider and model id |
| `context` | latest used tokens over configured context window, or unknown |
| `tokens` | latest and session cumulative token counts |
| `cost` | session and today spend |
| `memory` | durable, staged, episode, and fact counts |
| `intent` | last resolved intent |
| `skills` | active skill and always-eligible skill counts |
| `inbox` | pending approval count |
| `channel` | attached channel/session posture |
| `trace` | trace on/off |

Configure the catalog in TOML or from the REPL/TUI with `/statusline`.

## Privacy

Telemetry is local daemon state. It is not uploaded by the status line, `/telemetry`, or `allbert-cli telemetry --json`. Provider token usage and cost estimates come from model responses and Allbert's local accounting.

## Related Docs

- [TUI operator guide](tui.md)
- [Adaptive memory guide](adaptive-memory.md)
