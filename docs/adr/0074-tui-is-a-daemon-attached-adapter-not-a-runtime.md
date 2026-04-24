# ADR 0074: TUI is a daemon-attached adapter, not a runtime

Date: 2026-04-24
Status: Proposed

## Context

v0.11 adds a richer terminal UI. The tempting failure mode is to let the TUI grow into a second application runtime: its own session state, its own memory summaries, its own approval state, or its own cost accounting. That would violate the kernel-first and daemon-capable direction from the vision and would make future channels harder to reason about.

The existing classic REPL already attaches to daemon-hosted sessions. The TUI should improve rendering and interaction without changing ownership of runtime behavior.

## Decision

The v0.11 TUI is a frontend adapter over daemon sessions.

- The daemon/kernel own agent turns, tools, memory, cost, tracing, approvals, routing, model selection, and telemetry.
- The TUI owns terminal layout, input editing, transcript rendering, focus, modals, keyboard/mouse handling, and local status-line display.
- The TUI connects through the same local IPC protocol as the classic REPL.
- The TUI does not boot a private kernel and does not maintain authoritative copies of runtime state.
- The classic Reedline REPL remains available as `classic` mode and as the migration default for existing profiles.

Fresh profiles default to TUI, while upgraded profiles preserve classic mode unless the operator opts in.

## Consequences

**Positive**

- Runtime behavior remains testable at the kernel/daemon layer.
- Future frontends can consume the same protocol state.
- Terminal UI iteration does not create a second trust surface.
- Classic REPL remains a safe fallback for terminals where TUI behavior is undesirable.

**Negative**

- The TUI depends on protocol additions for rich status, rather than scraping local state directly.
- Some UI features require daemon changes before they can render meaningful data.

**Neutral**

- The TUI can later become the default for upgraded profiles after one release of operator feedback.

## References

- [docs/plans/v0.11-tui-and-memory.md](../plans/v0.11-tui-and-memory.md)
- [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md)
- [ADR 0013](0013-clients-attach-to-a-daemon-hosted-kernel-via-channels.md)
- [ADR 0024](0024-v0-2-primary-operator-surface-is-unified-under-allbert-cli.md)

