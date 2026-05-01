# ADR 0001: Signal-First Jido Runtime

## Status

Accepted.

## Context

Allbert is intended to grow from a local assistant loop into a multi-channel,
multi-agent personal runtime. The vision calls for CLI/REPL, Phoenix LiveView,
scheduled jobs, future chat/email/SMS adapters, memory systems, skills, and
specialist agents. If each surface calls agents or tools directly, the runtime
will become difficult to observe, secure, and extend.

The current application already starts `AllbertAssist.Jido` and a
`Jido.Signal.Bus` under OTP supervision. Jido also provides the vocabulary the
project wants: agents for bounded decision loops, actions for validated
capabilities, and signals for eventful coordination.

## Decision

Allbert input, jobs, tools, agents, memory events, traces, and channel adapters
will communicate through Jido signals and a supervised runtime boundary.

The first runtime boundary should accept user input, create an Allbert signal,
route it to the primary agent, execute selected actions through explicit
permission checks, and record response/trace signals. Channels should translate
between their external protocol and this signal-driven core rather than owning
agent logic themselves.

## Consequences

- CLI, LiveView, and future channels can share one assistant loop.
- Agent and action behavior becomes easier to trace because turns pass through
  named signals.
- Permissions can be enforced at the action boundary instead of being scattered
  across UI or channel code.
- The first implementation needs a little more structure than direct agent
  calls, but that structure is the foundation for safe growth.

