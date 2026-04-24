# ADR 0075: Session telemetry is kernel-owned protocol state

Date: 2026-04-24
Status: Proposed

## Context

The v0.11 TUI needs status-line data: provider, model, context pressure, token usage, cost, memory state, active skills, pending approvals, and trace posture. If the TUI computes that independently, it will drift from the daemon and classic CLI. If every frontend invents its own status query, Allbert loses the legibility the feature is meant to provide.

Telemetry is not just display state. It summarizes runtime facts that the kernel and daemon already own.

## Decision

v0.11 adds a daemon protocol telemetry surface:

- `ClientMessage::SessionTelemetry`
- `ServerMessage::SessionTelemetry(TelemetrySnapshot)`

`TelemetrySnapshot` is additive to `SessionStatus` and is the canonical source for TUI status-line rendering, `/telemetry`, `allbert-cli telemetry --json`, and future frontend status views.

The snapshot includes:

- session id, channel, turn state, current agent stack
- provider, model id, max output tokens, API-key status, optional context window
- latest model usage and cumulative session usage
- context percentage when context window is known
- session cost, today's cost, daily cap, and active turn budget
- memory synopsis bytes, ephemeral bytes, durable/staged/episode/fact counts
- active skills, always-eligible skills, last intent
- pending inbox count and trace state

Context usage is based on provider-reported latest response usage. v0.11 does not estimate preflight token counts.

## Consequences

**Positive**

- TUI, classic REPL, CLI, and future channels render the same runtime truth.
- Tests can assert telemetry without terminal rendering.
- Status-line behavior remains provider-free testable.
- Unknown context windows are explicit (`ctx ?`) rather than guessed.

**Negative**

- The protocol payload grows.
- Some fields are approximate until providers report richer usage.

**Neutral**

- `SessionStatus` remains for backward-compatible status flows.
- Future protocol versions may add preflight estimates if Allbert later adopts tokenizer-aware accounting.

## References

- [docs/plans/v0.11-tui-and-memory.md](../plans/v0.11-tui-and-memory.md)
- [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)
- [ADR 0066](0066-owned-provider-seam-over-rig-for-v0-10.md)
- [ADR 0074](0074-tui-is-a-daemon-attached-adapter-not-a-runtime.md)

