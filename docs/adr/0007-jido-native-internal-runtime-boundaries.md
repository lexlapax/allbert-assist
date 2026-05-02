# ADR 0007: Jido-Native Internal Runtime Boundaries

## Status

Accepted.

## Context

ADR 0001 made Allbert a signal-first Jido runtime. v0.02 added Settings
Central, and v0.03 added the Agent Skills substrate. Those implementations
correctly introduced Jido actions for user-facing capabilities, but several
surfaces still call domain modules directly: the intent agent manually invokes
action modules, Settings LiveView and Mix tasks call settings modules directly,
and trace writing reaches into memory internals.

That drift will become expensive once Security Central, confirmations, shell
execution, skill scripts, online imports, jobs, channels, and memory review all
need one policy and trace story.

At the same time, making every helper function into an agent would be the wrong
kind of uniformity. Jido actions are valuable at runtime boundaries because
they provide validation, structured results, observability, and composition.
Plain Elixir modules remain better for pure parsing, schemas, data
normalization, storage helpers, and deterministic transformations.

## Decision

Allbert adopts the Boundary Actions rule.

Externally invoked, effectful, security-relevant, or observable domain
operations should enter through signals, internal agents or runtime routers,
and registered Jido actions. Jido agents decide, route, coordinate, or own
stateful loops. Jido actions are the required boundary for validated
capabilities and side effects. Jido signals are the runtime event fabric for
user input, internal requests, action lifecycle, audit, trace, memory,
settings, skills, and security events.

Plain Elixir modules remain valid behind those boundaries for pure logic and
low-level implementation details.

## Consequences

- v0.04 becomes Jido Runtime Convergence Refactor.
- Security Central moves to v0.05 and consumes the converged boundary.
- The action runner becomes a required runtime boundary before action-backed
  skills, confirmations, execution adapters, jobs, and channels.
- Runtime-facing action invocation resolves through the action registry and
  shared runner so lifecycle signals, permission decisions, redaction,
  metadata, and future Security Central evaluation remain consistent.
- CLI, LiveView, jobs, and future channels should not own settings, skills,
  memory, trace, or security semantics.
- Direct domain calls remain acceptable inside registered actions, pure
  modules, migrations, and focused unit tests.
- Tests should cover both pure modules and action/runtime boundaries instead of
  pretending one style fits every layer.
- Implementation milestones must stay warning-free across compiler checks,
  formatter checks, Credo strict, Dialyzer, focused tests, and precommit.
