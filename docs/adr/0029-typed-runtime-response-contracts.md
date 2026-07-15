# ADR 0029: Typed Runtime Response Contracts

## Status

Accepted in v0.31 M6 Runtime And UI-Substrate Consolidation
(`docs/plans/archives/v0.31-plan.md`).

## Context

Actions, intent routing, objectives, confirmations, and UI surfaces currently
consume several map-shaped response variants. The lack of a single response
contract makes workspace panels and generated actions more likely to inspect
incidental keys.

## Decision

Allbert will add a typed runtime response contract for common outcomes:

- completed;
- needs confirmation;
- denied;
- advisory;
- error;
- unsupported or unavailable capability.

The contract should be convenient for actions and objective steps while still
rendering the same CLI and LiveView behavior that operators see today.

## Implementation Notes

v0.31 M6 adds `AllbertAssist.Runtime.Response` with builders and normalizers
for completed, confirmation-needed, denied, advisory, error, unsupported, and
unavailable results. `AllbertAssist.Runtime`, `AllbertAssist.Actions.Runner`,
`PermissionGate.response_status/1`, and representative objective execution
branches use the helper without changing existing operator-facing copy,
confirmation semantics, or transport protocol fields.

## v0.55 Amendment: Split Model/Surface Payloads

Status: Accepted for v0.55 Channel Parity + TUI/Terminal Channel
(`docs/plans/archives/v0.55-plan.md`; ADR 0067).

The typed response contract gains two optional fields:

- `model_payload` — canonical content threaded into conversation history,
  memory, and later model context.
- `surface_payload` — renderer-specific content for the current surface. For the
  TUI this may include terminal framing, paging hints, ANSI styling metadata, or
  live-region render data.

If neither field is present, existing `message` behavior remains the default. If
only `model_payload` is present, `surface_payload` defaults to `model_payload`.
Runtime and memory code must consume `model_payload`; renderers may consume
`surface_payload`. Terminal chrome, prompts, paging markers, and live-block
artifacts must never be stored as model-facing payload.

Implementation note (v0.55 M4): `AllbertAssist.Runtime.Response.normalize/2`
now fills `message`, `model_payload`, and `surface_payload` for both legacy
single-payload responses and split-payload responses. The TUI eval row
`split-payload-contract-001` verifies terminal `surface_payload` is rendered
while conversation history stores only `model_payload`.

## Consequences

- v0.32 panels can render action/objective status without special cases.
- v0.36 sandbox reports and v0.37 capability-gap/dynamic-trial reports can
  attach structured diagnostics.
- v0.37 generated actions and v0.38 templated actions can return the approved
  response shape.

## Non-Goals

- No copy rewrite unless implementation records a specific request-flow update.
- No permission change.
- No transport protocol change.

## Relates To

- Builds on: ADR 0007 (action runner result/lifecycle metadata).
- Under: ADR 0026 facade discipline.
- Consumed by: ADR 0030 (panels render action/objective status), ADR 0037 /
  ADR 0033 (sandbox-trial structured diagnostics); v0.32 through v0.38.
