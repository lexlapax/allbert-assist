# ADR 0033: Capability Gap Acquisition And Trust Tiers

## Status

Proposed for v0.36 Dynamic Code & Config Generation and Live Capability
Integration (`docs/plans/v0.36-plan.md`). Amended for the v0.36 reframe: trust
tiers now include a gated `:integrated` tier (live in-core capability) and a
`:rolled_back` tier, and the capability-gap flow permits proactive
generation/trial with integration-only confirmation. See ADR 0032 (gated
in-core integration) and ADR 0035 (code-gen agents and loader).

## Context

ADR 0021 reserves capability inventory and acquisition vocabulary for future
objective work. Dynamic plugin/app drafts need that vocabulary before the
system can safely propose generation in response to a missing capability.

## Decision

Capability acquisition is objective-owned:

- intent or action planning may report a missing capability;
- the objective runtime records a capability gap;
- acquisition options are advisory proposals, not authority;
- generating a draft, compiling it in sandbox, and running a trial are
  registered actions that may run **proactively** (no operator confirmation)
  because they are confined to the untrusted sandbox phase and grant no
  authority;
- **integrating** a draft into the live core node, discarding it, or rolling it
  back are registered actions with explicit Security Central decisions and
  **mandatory operator confirmation**.

v0.36 defines draft trust tiers:

- `:draft` - inert generated source;
- `:sandbox_compiled` - compiled in the OS-level sandbox;
- `:sandbox_trialed` - trial scenarios ran in the sandbox;
- `:gate_passed` - cleared the full warning gate (compile-WAE, Credo, Dialyzer,
  tests, security evals) inside the sandbox; eligible for integration;
- `:integrated` - operator-confirmed and hot-loaded/registered live in the core
  node (ADR 0032 gated path, ADR 0035 loader);
- `:rolled_back` - integration reverted live (purged + unregistered);
- `:discarded` - no longer active.

Only `:integrated` grants live core-node loading and registration, and only via
the ADR 0032 gate (sandbox trial + warning gate + operator confirmation). No
other tier grants action permissions, route authority, settings authority,
skill enablement, child supervision, or core-node module loading. No tier is
reached by advisory/agent output or by an auto-trial result alone.

## Consequences

- Dynamic generation remains part of the objective runtime instead of becoming
  a hidden goal loop inside an app, plugin, or LiveView.
- Operator review is explicit at each authority boundary.
- A gate-passed draft is reviewed as an internal v0.36 step; reaching
  `:integrated` requires operator confirmation and is never an automatic
  promotion.

## Non-Goals

- No autonomous skill creation from traces.
- No automatic capability acquisition.
- No approval from model/advisory output.
- No bypass of existing confirmation or Resource Access policy.

## Relates To

- Implements: ADR 0021 reserved capability-inventory / gap / acquisition-option
  vocabulary.
- Paired with: ADR 0032 (dynamic generation and sandboxed loading).
- Depends on: ADR 0029 (typed responses for structured trial diagnostics), ADR
  0026-0031 (v0.31 facades), and the objective runtime (ADR 0021).
- Constrained by: ADR 0006 (Security Central) and existing confirmation /
  Resource Access policy.
- Enables: v0.37 Templated Creation, which reuses these trust tiers and the
  v0.36 sandbox/gate/loader to validate and (optionally) integrate templated
  plugin/app/tool/code artifacts.
