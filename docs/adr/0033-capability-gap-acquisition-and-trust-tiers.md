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

- intent or action planning may report a missing capability, but that report is
  advisory;
- the objective runtime records a capability gap only after an explicit
  operator request to create/generate a missing capability or an explicit
  objective step proposal that no existing registered action/app can satisfy;
- acquisition options are advisory proposals, not authority;
- generating a draft, compiling it in the v0.36 sandbox, and running a trial may
  run only from that explicit operator/objective gap while confined to the
  untrusted sandbox phase;
- integrating a draft into the live core node, discarding it, or rolling it back
  are registered actions with Security Central decisions; integration and
  rollback require mandatory operator confirmation.

v0.37 does not start generation solely from low intent confidence, rejected
candidate diagnostics, or classifier output. Those signals may suggest that
generation is available, but proactive auto-acquisition from ranking confidence
is deferred.

The lifecycle maps onto the `Objectives.Engine` seven-stage state machine rather
than a private loop. The capability gap and acquisition options surface in the
propose/evaluate stages; `GenerateDraft`/`RunDraftTrial`/`RunDraftGate` are
advisory/evidence steps that grant no authority; and
`IntegrateDraft`/`RollbackIntegration` are the authorize-then-execute steps gated
by mandatory Security Central confirmation. Each transition is recorded as an
`objective_event`, and `objective_id`/`step_id` remain correlation data, never
authority.

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
the ADR 0032 gate. Even at `:integrated`, generated authority is limited to the
v0.37 generated-permission ceiling, validated runtime call targets, and normal
registered action/app boundaries. No other tier grants action permissions, route
authority, settings authority, skill enablement, child supervision, or core-node
module loading. No tier is reached by advisory/agent output alone.

Legal tier transitions are explicit:

| From | To | Requirement |
|---|---|---|
| none | `:draft` | Explicit operator/objective gap proposal plus enabled workflow and valid advisory provider profile |
| `:draft` | `:sandbox_compiled` | v0.36 sandbox compile evidence over scanned, staged source |
| `:sandbox_compiled` | `:sandbox_trialed` | v0.36 sandbox trial evidence over the same draft revision |
| `:sandbox_trialed` | `:gate_passed` | v0.36 warning gate plus v0.37 static/integrity checks pass |
| `:gate_passed` | `:integrated` | Mandatory Security Central confirmation and ADR 0032/0035 loader success |
| `:integrated` | `:rolled_back` | Mandatory Security Central confirmation and audited authority removal |
| any non-`:integrated` tier | `:discarded` | Registered discard action; `:integrated` artifacts must roll back first |
| `:rolled_back` | `:discarded` | Registered discard action after live authority has been removed |

Repair after sandbox, gate, review, or loader failure creates a new draft
revision with a parent-revision pointer. It does not mutate the evidence for an
older revision or move an old `:gate_passed` artifact backward in place. A
rolled-back artifact cannot be re-integrated directly; restoring a capability
requires a new or revalidated draft revision to pass the gate and receive a new
operator confirmation. A same-name replacement revision cannot integrate while
the older revision is still `:integrated`; v0.37 requires rollback first and
defers atomic supersede. `:discarded` is terminal for that revision.

## Consequences

- Dynamic generation remains part of the objective runtime instead of a hidden
  goal loop inside an app, plugin, or LiveView.
- Operator review is explicit at each authority boundary.
- A gate-passed draft is evidence, not a trust grant; reaching `:integrated`
  requires operator confirmation and is never automatic.
- Trust tiers do not override the generated-permission ceiling. A live dynamic
  action can only expose permissions and runtime call targets accepted by the
  loader validator.

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
