# ADR 0032: Dynamic Plugin Generation And Sandboxed Loading

## Status

Proposed for v0.35 Dynamic Plugin/App Generation And Sandboxed Module Loading
(`docs/plans/v0.35-plan.md`).

## Context

Allbert currently forbids auto-generating, compiling, or loading Elixir modules
from arbitrary skill, plugin, YAML, or user-created folders. ADR 0017 likewise
keeps home plugins metadata-only for code-bearing contributions. This is the
right default: Elixir dynamic compile/eval APIs execute with the same
privileges as the Erlang VM and can compromise the host if used on untrusted
input.

The product vision still needs a future path where Allbert can try a generated
local capability when no existing plugin/app/action can satisfy a request.

## Decision

v0.35 defines a narrow exception to the no-dynamic-code rule:

- generated plugin/app source may be written inertly under
  `<ALLBERT_HOME>/plugins/<slug>`;
- generated code may be compiled and loaded only in an out-of-node sandbox or
  disposable trial runtime;
- the core Allbert BEAM node must not call `Code.compile_*`, `Code.eval_*`,
  `Code.require_*`, or equivalent module-loading APIs on generated source;
- trial communication flows through a narrow, redacted, audited gateway;
- generated drafts remain untrusted until a later reviewed integration path.

This exception does not weaken the rule for skill folders, YAML agents, plugin
manifests, remote plugins, or arbitrary user-created code.

## Consequences

- Allbert can experiment with a generated local capability without granting it
  in-process authority.
- Security evals must prove core-node loading, promotion bypass, dependency
  injection, migration injection, secret access, and sandbox escape attempts
  fail closed.
- ADR 0017 remains accepted for shipped/project/home plugin defaults, with
  this ADR as a future bounded exception for sandbox trials.

## Non-Goals

- No remote marketplace.
- No package-manager execution.
- No new dependencies or migrations in generated drafts.
- No automatic promotion into reviewed source.
- No arbitrary BEAM hot loading in the core node.
- No treating a separate or hidden BEAM/distributed-Erlang node as the isolation
  boundary.

## Sandbox Isolation Requirement (decision detail)

"Out-of-node" means a real OS-level isolation boundary: a separate OS process
with dropped privileges and restricted filesystem/network access, or a
container/VM. It does **not** mean a separate or hidden BEAM/distributed-Erlang
node, and not an in-VM "disposable process," because BEAM processes share the
host VM's privileges (ADR 0009). v0.35 must select a concrete backend that
provides an OS-level boundary before sandbox compilation lands; the parked
"Container And Remote Execution Sandboxes" Level-2/Level-3 work is a
prerequisite of v0.35, not an implementation detail. If no OS-level backend is
available on the host, dynamic trials remain disabled rather than degrading to
an in-VM process.

## Relates To

- Bounded exception to: the AGENTS.md "no dynamic module loading" non-negotiable
  and ADR 0017 (home plugins stay metadata-only by default).
- Constrained by: ADR 0009 (BEAM and child processes are not an OS boundary) and
  ADR 0006 (Security Central authority).
- Depends on: ADR 0026-0031 (v0.31 consolidated facades — paths, redaction,
  audit, action DSL, typed responses, extension registry) and a graduated
  Level-2/Level-3 execution sandbox.
- Paired with: ADR 0033 (capability-gap acquisition and trust tiers).
