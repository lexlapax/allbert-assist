# ADR 0032: Dynamic Plugin Generation And Sandboxed Loading

## Status

Proposed for v0.34 Dynamic Plugin/App Generation And Sandboxed Module Loading
(`docs/plans/v0.34-plan.md`).

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

v0.34 defines a narrow exception to the no-dynamic-code rule:

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
