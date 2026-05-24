# ADR 0035: Code-Gen Agents And Gated Live Integration Loader

## Status

Proposed for v0.36 Dynamic Code & Config Generation and Live Capability
Integration (`docs/plans/v0.36-plan.md`). Pairs with ADR 0032 (untrusted-trial
sandbox + gated in-core integration exception) and ADR 0033 (capability gap and
trust tiers, including `:integrated`).

## Context

The v0.36 reframe gives Allbert a self-extending capability: detect a capability
gap, generate code **and config** to the proven v0.27–v0.35 contract shapes,
trial it in an OS-level sandbox, and — after the warning gate and operator
confirmation — hot-load it into the live core node without a restart. Two new
substrates are needed: (1) a committee of code-generation agents to author the
artifact, and (2) a loader that integrates an approved artifact into the running
runtime and can reverse it. This ADR records their boundaries.

Code-generation research converges on a multi-agent Planner→Author→Tester→
Critic→Repair loop grounded in sandboxed execution; ~45% of AI-generated code
fails security tests, so the loop is advisory and every authority decision stays
with the gate and the operator.

## Decision

### 1. Code-gen agents are advisory proposers

A committee of supervised `Jido.Agent` agents (reusing the v0.25 StockSage
native-agent + Jido.AI pattern) authors drafts:

- `Codegen.Planner` — capability gap → generation spec;
- `Codegen.Author` — spec → code + config to the proven contract shapes;
- `Codegen.TrialAuthor` — spec → trial scenarios and tests;
- `Codegen.Critic` — self-review against contracts, non-negotiables, and
  redaction rules;
- `Codegen.Repair` — sandbox/gate failure diagnostics → re-author loop.

Per ADR 0021, agent output is **never** authority. It cannot enable, trust,
integrate, or grant anything. The deterministic, template-driven path (Mix
tasks, operator flows, Canvas surface) is a separate milestone, v0.37
(Templated Creation), which reuses this engine's sandbox/gate/loader rather than
free LLM authoring.

### 2. Generation targets code and config

Generated artifacts cover the full contract surface: plugin/app manifest,
modules, `AllbertAssist.Action` actions, `SurfaceProvider` panels and
`intent_descriptors`, settings fragments, memory namespace, objective wiring,
and theming/layout stubs. Generation is language-pluggable behind a
`CodeGenTarget` behaviour; v0.36 ships the Elixir/OTP target only. Other
languages remain parked (Scripting Engine / Execution Sandboxes future work).

### 3. The live-integration loader is gated, audited, and reversible

`AllbertAssist.DynamicPlugins.Loader` integrates an approved artifact into the
running node without a restart, only when the ADR 0032 gate is satisfied
(`:gate_passed` + operator confirmation → `:integrated`):

- it recompiles the **operator-reviewed source** in core (you load the source
  you reviewed) with an integrity hash, rather than loading an opaque
  sandbox-built binary;
- it registers the new capability live: a **runtime-mutable actions overlay**
  on `AllbertAssist.Actions.Registry`, the existing `App.Registry` (ETS), a
  `DynamicSupervisor` for any child specs, and the runtime catalog/destinations;
- it emits audit events for compile, load, register, and rollback;
- it supports `rollback/1` (purge modules + unregister) to reach `:rolled_back`
  live. Page-route surfaces still require a restart; panel/destination apps go
  fully live.

### 4. Proactive trial, confirmed integration

Generation and sandbox trial may run proactively on a detected gap. Only
integration (and discard/rollback) requires operator confirmation at the
Security Central boundary.

## Consequences

- Allbert can stand up a new plugin/app capability live, with the operator
  confirmation as the trust grant and a one-call rollback.
- The actions registry gains a runtime-mutable overlay; this is new
  infrastructure and must preserve all existing capability/permission/app-scope
  semantics for both static and dynamically registered actions.
- Security evals must prove: untrusted core-load attempts, gate-skip,
  unapproved/auto integration, loader provenance/integrity tampering, rollback
  correctness, and exfiltration all fail closed.

## Non-Goals

- No autonomous integration; integration is always operator-confirmed.
- No agent or auto-trial authority over enablement, trust, or permissions.
- No remote marketplace, dependency/migration/NIF additions, or untrusted binary
  loading.
- No multi-language target in v0.36 beyond Elixir/OTP.

## Relates To

- Pairs with: ADR 0032 (sandbox + gated in-core integration) and ADR 0033
  (trust tiers, capability gap).
- Builds on: ADR 0021 (advisory output is never authority), ADR 0006 (Security
  Central), ADR 0026–0031 (v0.31 facades), ADR 0027 (`AllbertAssist.Action`),
  and the v0.25 native-agent + Jido.AI precedent.
- Constrained by: ADR 0009 (BEAM is not an OS boundary — untrusted trial stays
  OS-isolated).
- Enables: v0.37 Templated Creation (Mix tasks, operator flows, Canvas surface)
  on the same sandbox/gate/loader engine.
