# Plans

Plans describe release scope, request flow, validation, and handoff. Use the
[roadmap](roadmap.md) as the canonical planning index; it links the versioned
plan and request-flow documents.

## Current And Next

- [Roadmap](roadmap.md)
Listed in ship order after the 2026-08-06 resequencing.

- [v1.4 spine enablers plan](v1.4-plan.md) and
  [request flow](v1.4-request-flow.md) (readiness rewrite completed 2026-08-06;
  ready to execute M0, with implementation beyond its evidence barriers closed
  until v1.3.2 and the real-migration/dependency inventories pass)
- [v1.5 Knowledge Stage 1 plan](v1.5-plan.md) and
  [request flow](v1.5-request-flow.md) (planned; readiness passes not yet run)
- [v1.6 Knowledge Central plan](v1.6-plan.md) and
  [request flow](v1.6-request-flow.md) (planned; readiness passes not yet run)
- [v1.7 connectivity enablers plan](v1.7-plan.md) and
  [request flow](v1.7-request-flow.md) (planned; readiness passes not yet run)
- [v1.8 adaptive usage profiling plan](v1.8-plan.md) and
  [request flow](v1.8-request-flow.md) (planned; readiness **reset** — it was
  implementation-ready as v1.4, but unbundling removed two milestones and its
  anchors now sit six releases upstream)
- [Allbert Jido vision](allbert-jido-vision.md)
- [Future features](future-features.md)

## Archives

Every released version's plan/request-flow pair (v0.01 through v1.3.2, plus the
v1.0 handoff) lives in [archives/](archives/). They are shipped-history working records:
search them for provenance and past decisions; the roadmap and CHANGELOG are the
authoritative summaries.

- [Overall Allbert kernel redo analysis](archives/overall-allbert-kernel-redo-analysis.md)
  — **accepted 2026-08-06 and archived.** Its decisions are binding through
  [ADR 0098](../adr/0098-kernel-application-pack-contract-and-tier-model.md),
  which is the authority; the analysis is retained for the measurements and
  reasoning behind them. Note the ADR records two places the operator overrode
  it, and §13.3 carries a numbering note because it predates the 2026-08-06
  resequencing.

- [v1.1 asynchronous fan-out shipped plan](archives/v1.1-plan.md) and
  [request flow](archives/v1.1-request-flow.md)
- [v1.2 zero-click first run shipped plan](archives/v1.2-plan.md) and
  [request flow](archives/v1.2-request-flow.md)
- [v1.3 long-term memory and Search Central shipped plan](archives/v1.3-plan.md)
  and [request flow](archives/v1.3-request-flow.md)
- [v1.3.1 qualification and corrective-hardening shipped source plan](archives/v1.3.1-plan.md)
  and [request flow](archives/v1.3.1-request-flow.md)
- [v1.3.2 foundational-enablers shipped source plan](archives/v1.3.2-plan.md)
  and [request flow](archives/v1.3.2-request-flow.md)

## Conventions

- `vX.Y-plan.md` defines release scope, milestones, dependencies, and gates.
- `vX.Y-request-flow.md` defines operator flows, validation, and evidence.
- Historical version plans move to [archives/](archives/) for auditability.
- Superseded broad planning notes live in [archives](../archives/README.md).

## Release Status

Use [CHANGELOG.md](../../CHANGELOG.md) for shipped release details. Use active
plans and request flows for current implementation scope.
