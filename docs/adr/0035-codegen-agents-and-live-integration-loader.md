# ADR 0035: Code-Gen Agents And Gated Live Integration Loader

## Status

Proposed for v0.37 Dynamic Code & Config Generation and Live Capability
Integration (`docs/plans/v0.37-plan.md`). Pairs with ADR 0032 (untrusted trial
and gated integration), ADR 0033 (trust tiers), and ADR 0037 (v0.36 Elixir/OTP
sandbox/gate runner).

## Context

With v0.36 providing the sandbox/gate runner, v0.37 can add the
self-extending-runtime layer: detect a capability gap, generate Elixir/OTP code
and config to proven v0.27-v0.35 shapes, trial it in the sandbox, and — after
the gate plus operator confirmation — hot-load it into the live core node
without a restart.

Two substrates are needed:

1. advisory code-generation agents that author and repair drafts;
2. a loader that integrates an approved artifact into the running runtime and
   can reverse it.

## Decision

### 1. Code-gen agents are advisory proposers

A committee of supervised `Jido.Agent` agents, reusing the v0.25 StockSage
native-agent + Jido.AI pattern, authors drafts:

- `Codegen.Planner` - capability gap to generation spec;
- `Codegen.Author` - spec to code/config;
- `Codegen.TrialAuthor` - spec to sandbox trial scenarios/tests;
- `Codegen.Critic` - self-review against contracts and non-negotiables;
- `Codegen.Repair` - sandbox/gate diagnostics to re-author loop.

Per ADR 0021, agent output is never authority. It cannot enable, trust,
integrate, grant permissions, or bypass confirmation. The deterministic
template path is v0.38 and reuses this engine only when live integration is
selected.

### 2. Generation targets Elixir/OTP code and config

Generated artifacts cover the reviewed Allbert contract surface: plugin/app
manifest, modules, `AllbertAssist.Action` actions, panel surfaces, intent
descriptors, settings fragments, memory namespace, objective wiring, and
theming/layout stubs. v0.37 ships only the Elixir/OTP target. Other languages
remain parked.

### 3. The live-integration loader is gated, audited, and reversible

`AllbertAssist.DynamicPlugins.Loader` integrates an approved artifact into the
running node without a restart only when the ADR 0032 gate is satisfied:
`:gate_passed` plus operator confirmation.

The loader:

- verifies source hash, provenance, and manifest-declared module set;
- enforces generated namespace rules and rejects replacement of core/static
  modules, undeclared modules, dynamic protocols, router edits, application env
  mutation, migrations, dependency additions, NIFs, ports, and package-manager
  hooks;
- recompiles the operator-reviewed source in core, not an opaque sandbox-built
  binary;
- registers a runtime-mutable actions overlay on
  `AllbertAssist.Actions.Registry`;
- registers app/panel/destination entries through runtime registries;
- starts declared children through a `DynamicSupervisor`;
- emits audit events for compile, load, register, and rollback;
- supports rollback by stopping children, unregistering entries, and purging
  loaded modules where safe.

The actions overlay denies collisions rather than shadowing static, plugin,
app, or other dynamic actions. Rollback requires operator confirmation and
guarantees removal of authority surfaces; BEAM module purge/delete is attempted
and audited as best effort.

Page-route surfaces still require a restart; panel/destination apps integrate
fully live.

### 4. Proactive trial, confirmed integration

Generation and sandbox trial may run proactively on a detected gap because they
grant no live authority. Integration and rollback require operator confirmation
at the Security Central boundary. Draft metadata, provenance, repair history,
and sandbox reports are file-backed under
`<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/`.

## Consequences

- Allbert can stand up a new plugin/app capability live after the operator
  grants trust.
- The actions registry gains a runtime-mutable overlay that must preserve all
  existing capability/permission/app-scope semantics.
- Security evals must prove untrusted core-load attempts, gate skip,
  unapproved/auto integration, loader tampering, core-module replacement,
  action shadowing, rollback failure, and exfiltration fail closed.

## Non-Goals

- No autonomous integration.
- No agent or auto-trial authority over enablement, trust, or permissions.
- No remote marketplace, dependency/migration/NIF additions, package-manager
  execution, or untrusted binary loading.
- No multi-language target beyond Elixir/OTP.
- No template gallery, Mix generator UX, or Canvas Create destination; that is
  v0.38.

## Relates To

- Depends on: ADR 0037 (v0.36 sandbox/gate runner).
- Pairs with: ADR 0032 (sandbox + gated integration) and ADR 0033 (trust tiers,
  capability gap).
- Builds on: ADR 0021, ADR 0006, ADR 0026-0031, ADR 0027, and the v0.25
  native-agent + Jido.AI precedent.
- Enables: v0.38 Templated Creation on the same sandbox/gate/loader path.
