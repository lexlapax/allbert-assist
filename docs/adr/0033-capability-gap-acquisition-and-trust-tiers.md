# ADR 0033: Capability Gap Acquisition And Trust Tiers

## Status

Proposed for v0.34 Dynamic Plugin/App Generation And Sandboxed Module Loading
(`docs/plans/v0.34-plan.md`).

## Context

ADR 0021 reserves capability inventory and acquisition vocabulary for future
objective work. Dynamic plugin/app drafts need that vocabulary before the
system can safely propose generation in response to a missing capability.

## Decision

Capability acquisition is objective-owned:

- intent or action planning may report a missing capability;
- the objective runtime records a capability gap;
- acquisition options are advisory proposals, not authority;
- generating a draft, compiling it in sandbox, running a trial, discarding it,
  or marking it as a promotion candidate are registered actions with explicit
  Security Central decisions and operator confirmation.

v0.34 defines draft trust tiers:

- `:draft` - inert generated source;
- `:sandbox_compiled` - compiled outside the core node;
- `:sandbox_trialed` - trial scenarios ran outside the core node;
- `:promotion_candidate` - operator marked for future reviewed integration;
- `:discarded` - no longer active.

No trust tier grants action permissions, route authority, settings authority,
skill enablement, child supervision, or core-node module loading.

## Consequences

- Dynamic generation remains part of the objective runtime instead of becoming
  a hidden goal loop inside an app, plugin, or LiveView.
- Operator review is explicit at each authority boundary.
- v0.35 can consume promotion-candidate drafts as review input without making
  v0.34 a generator-promotion feature.

## Non-Goals

- No autonomous skill creation from traces.
- No automatic capability acquisition.
- No approval from model/advisory output.
- No bypass of existing confirmation or Resource Access policy.
