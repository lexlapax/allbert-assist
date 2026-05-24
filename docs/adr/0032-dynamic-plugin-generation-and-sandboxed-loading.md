# ADR 0032: Dynamic Plugin Generation And Sandboxed Loading

## Status

Proposed for v0.36 Dynamic Code & Config Generation and Live Capability
Integration (`docs/plans/v0.36-plan.md`). Amended below for the v0.36 reframe:
the milestone now adds a gated in-core integration path on top of the
untrusted-trial sandbox, driven by an LLM code-gen agent committee. The
deterministic, template-driven developer/operator generator stays a separate
milestone, v0.37 (Templated Creation), which reuses this sandbox/gate/loader
path. See ADR 0033 (trust tiers) and ADR 0035 (code-gen agents and the
live-integration loader).

## v0.36 Reframe Amendment (Untrusted Trial vs Gated In-Core Integration)

The original decision (below) forbade any core-node loading of generated code.
The reframe keeps that rule for **untrusted** generated code and adds a single,
narrow, **gated** exception for **trusted** integration. The two phases are
strictly separated:

1. **Untrusted phase (unchanged):** generated code is compiled and trialed only
   in an OS-level sandbox. The default backend is a **local container
   (Docker/Podman)**; gVisor/Firecracker-class microVMs are the stronger future
   tier. BEAM processes and distributed-Erlang nodes are still **not** a valid
   boundary (ADR 0009). If no OS backend is configured, the workflow stays
   disabled. Proactive auto-generation and auto-trial are permitted in this
   phase; they grant no authority.
2. **Integration gate (new — the trust grant):** an artifact may leave the
   untrusted phase only when it (a) passed the sandbox trial, (b) passed the
   **same warning gate as human-authored code inside the sandbox**
   (`compile --warnings-as-errors`, `credo --strict`, `dialyzer`, focused
   tests, and the v0.36 security evals), and (c) received **explicit operator
   confirmation**. That confirmation is the trust grant at the Security Central
   action boundary; advisory/agent output and auto-trials never authorize it.
3. **Trusted phase (new):** a gate-passing, operator-confirmed artifact may be
   **hot-loaded into the core BEAM node and registered live without a restart**
   (trust tier `:integrated`, ADR 0033), via the audited, reversible loader in
   ADR 0035. Integration is reversible without a restart (tier `:rolled_back`).
   Loader provenance: the loader recompiles the **operator-reviewed source** in
   core (you load the source you reviewed) with an integrity hash; it does not
   trust an opaque sandbox-built artifact.

Route-based page surfaces still require a restart (compile-time router);
panel/destination apps (v0.34) integrate fully live.

## Context

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

v0.36 defines a narrow exception to the no-dynamic-code rule:

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
- No **untrusted** in-core loading: only a gate-passing, operator-confirmed
  artifact may be hot-loaded into the core node (see the v0.36 Reframe
  Amendment). Integration without the gate or without operator confirmation is
  forbidden.
- No treating a separate or hidden BEAM/distributed-Erlang node as the
  untrusted-trial isolation boundary.
- No integration authorized by advisory/agent output or by an auto-trial result
  alone.

## Sandbox Isolation Requirement (decision detail)

"Out-of-node" means a real OS-level isolation boundary: a separate OS process
with dropped privileges and restricted filesystem/network access, or a
container/VM. It does **not** mean a separate or hidden BEAM/distributed-Erlang
node, and not an in-VM "disposable process," because BEAM processes share the
host VM's privileges (ADR 0009). v0.36 must select a concrete backend that
provides an OS-level boundary before sandbox compilation lands; the parked
"Container And Remote Execution Sandboxes" Level-2/Level-3 work is a
prerequisite of v0.36, not an implementation detail. If no OS-level backend is
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
