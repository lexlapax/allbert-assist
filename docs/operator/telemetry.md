# Telemetry operator guide

Telemetry and activity are the current v0.15.0 live visibility surfaces. The TUI, classic REPL, CLI, Telegram, jobs, and future frontends all read daemon-owned state instead of guessing from frontend timers.

This guide covers **live** runtime visibility. Durable, after-the-fact session **replay** is documented in the [tracing operator guide](tracing.md). Use this guide to answer "what is Allbert doing right now?"; use the tracing guide to answer "what happened in that session, and why?" Start with the [v0.15.0 operator playbook](../onboarding-and-operations.md) for the full feature-test path.

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

Use activity when you want the live answer to "what is Allbert doing right now?":

```text
/activity
```

```bash
cargo run -p allbert-cli -- activity
cargo run -p allbert-cli -- activity --json
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
- active adapter id, base model, provenance, trained-at timestamp, and golden pass rate when a local adapter is active
- current daemon-owned activity snapshot when attached through protocol v3
- setup version

Token and context values are provider-reported from the latest model response. Allbert does not estimate preflight context pressure with a tokenizer.

## Activity Snapshot

`ActivitySnapshot` is live operational state, not a trace or replay artifact. It includes:

- phase, label, session id, channel, start time, and elapsed time
- optional current tool name and bounded tool summary
- optional active skill name or approval id
- optional stuck hint and next actions

The daemon derives this state from bounded kernel activity transitions and filters it per client protocol. v2 clients do not receive v3-only activity fields or messages. v0.14 diagnosis runs use `ActivityPhase::Diagnosing`; `unix_pipe` uses the existing tool activity posture with `tool_name = "unix_pipe"`. Activity snapshots are not persisted spans; v0.12.2 durable tracing and replay is the separate history surface.

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
| `adapter` | active adapter id, or none |

Configure the catalog in TOML or from the REPL/TUI with `/statusline`.

## Privacy

Telemetry is local daemon state. It is not uploaded by the status line, `/telemetry`, or `allbert-cli telemetry --json`. Provider token usage and cost estimates come from model responses and Allbert's local accounting.

## Related Docs

- [TUI operator guide](tui.md)
- [v0.15.0 operator playbook](../onboarding-and-operations.md)
- [Adaptive memory guide](adaptive-memory.md)
- [Personalization guide](personalization.md)
- [Self-diagnosis and local utilities](self-diagnosis-and-utilities.md)
- [Telegram operator guide](telegram.md)
- [Tracing operator guide](tracing.md) — durable session span replay (v0.12.2)
