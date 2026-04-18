# ADR 0001: Kernel is runtime core; frontends are adapters

Date: 2026-04-17
Status: Accepted

## Context

Allbert starts with a REPL because that is the fastest way to make the system usable, but the project vision is broader than a terminal app. [`docs/vision.md`](../vision.md) points toward a long-lived assistant runtime with future scheduling, gateways, memory maintenance, and other integration surfaces. If the first implementation is REPL-centric, the CLI will quietly become the real architecture and later frontends will be forced to tunnel through terminal assumptions.

The early decision that matters is not "should there be a CLI?" but "what owns the agent loop, tools, memory, cost accounting, and policy?" That ownership boundary will shape every later feature.

## Decision

Allbert will be structured as a Rust workspace with a library crate, `allbert-kernel`, and one or more frontend crates such as `allbert-cli`.

The kernel owns:
- the agent loop
- provider dispatch
- tool registry and tool execution
- skill discovery and activation
- memory reads/writes
- security policy enforcement
- cost accounting and tracing hooks

Frontends own:
- user-facing input and output
- confirmation UX
- shell/terminal rendering concerns
- frontend-specific commands and session ergonomics

The interface between them is an explicit adapter boundary rather than implicit terminal coupling.

## Consequences

**Positive**
- The REPL can ship first without becoming the architecture center.
- Future frontends such as cron, web, or message adapters can reuse the same runtime behavior.
- Security, memory, and tool policy stay in one place instead of being reimplemented per frontend.

**Negative**
- More upfront structure than a single binary crate.
- Some features that feel "simple in the CLI" require designing a reusable kernel API first.

**Neutral**
- Frontend adapters become a first-class concept early.
- Tests can target the kernel directly, without going through a REPL.

## References

- [docs/plans/v0.1-mvp.md](../plans/v0.1-mvp.md)
- [docs/vision.md](../vision.md)
