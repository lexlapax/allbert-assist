# ADR 0033: Capability Gap Acquisition And Trust Tiers

## Status

Proposed for v0.37 Dynamic Code & Config Generation and Live Capability
Integration (`docs/plans/v0.37-plan.md`). Revised after the v0.36 second pass:
v0.36 owns the sandbox evidence states; v0.37 owns capability-gap acquisition,
dynamic draft trust tiers, gated integration, and rollback.

## Context

ADR 0021 reserves capability inventory and acquisition vocabulary for objective
work. Dynamic plugin/app drafts need that vocabulary before the system can
safely propose generation in response to a missing capability.

## Decision

Capability acquisition is objective-owned:

- intent or action planning may report a missing capability;
- the objective runtime records a capability gap;
- acquisition options are advisory proposals, not authority;
- generating a draft, compiling it in the v0.36 sandbox, and running a trial may
  run proactively only while confined to the untrusted sandbox phase;
- integrating a draft into the live core node, discarding it, or rolling it back
  are registered actions with Security Central decisions; integration and
  rollback require mandatory operator confirmation.

Draft lifecycle state is file-backed under
`<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/` with metadata, provenance,
source hashes, diagnostics, and sandbox reports. It is not stored in Settings
Central and is not placed in ordinary plugin discovery roots while untrusted.

v0.37 defines draft trust tiers:

- `:draft` - inert generated source;
- `:sandbox_compiled` - compiled by the v0.36 sandbox;
- `:sandbox_trialed` - trial scenarios ran in the v0.36 sandbox;
- `:gate_passed` - cleared the v0.36 warning gate plus v0.37 static/integrity
  checks; eligible for operator review;
- `:integrated` - operator-confirmed and hot-loaded/registered live in the core
  node through ADR 0032/0035;
- `:rolled_back` - integration reverted live;
- `:discarded` - no longer active.

Only `:integrated` grants live core-node loading and registration, and only via
the ADR 0032 gate. No other tier grants action permissions, route authority,
settings authority, skill enablement, child supervision, or core-node module
loading. No tier is reached by advisory/agent output alone.

## Consequences

- Dynamic generation remains part of the objective runtime instead of a hidden
  goal loop inside an app, plugin, or LiveView.
- Operator review is explicit at each authority boundary.
- A gate-passed draft is evidence, not a trust grant; reaching `:integrated`
  requires operator confirmation and is never automatic.

## Non-Goals

- No autonomous skill creation from traces.
- No automatic capability acquisition.
- No approval from model/advisory output.
- No bypass of existing confirmation or Resource Access policy.

## Relates To

- Implements: ADR 0021 reserved capability-inventory / gap /
  acquisition-option vocabulary.
- Depends on: ADR 0037 (v0.36 sandbox evidence), ADR 0029 (typed diagnostics),
  ADR 0026-0031 (v0.31 facades), and the objective runtime.
- Paired with: ADR 0032 (dynamic generation and sandboxed loading) and ADR 0035
  (code-gen agents and live loader).
- Enables: v0.38 Templated Creation, which reuses these trust tiers and the
  v0.36/v0.37 gated path for optional live integration.
