# ADR 0065: Central Action Param-Contract Enforcement

Status: Proposed (v0.59 M7).
Date: 2026-06-21
Related: ADR 0064 (central slot/param normalization seam - predecessor), ADR
0027 (action DSL and capability registry), ADR 0006 (Security Central), ADR 0060
(two-stage router), ADR 0062 (intent descriptor lifecycle), and
`docs/plans/v0.59-plan.md`.

## Context

ADR 0064 closed the v0.54 intent slot -> action-param shape seam and corrected
Runner `:invalid_params` semantics for non-map params. It deliberately did not
make every action's registered schema centrally enforceable. That larger change
has a wider blast radius:

- action modules declare schemas through `use AllbertAssist.Action` /
  `Jido.Action`, but the Runner currently calls action `run/2` directly;
- many actions hand-roll param guards and key normalization;
- intent and channel callers inject context keys such as `user_id`,
  `thread_id`, `session_id`, and source text that are not always part of the
  action's declared schema; and
- making schema validation strict can change behavior across the whole action
  catalog.

The result is inconsistent with the project's central-registration posture:
capability, permission, and confirmation metadata resolve centrally, while
param contracts are still enforced action by action.

## Decision

v0.59 M7 will add a central action param-contract seam at the Runner boundary.
The exact implementation is refined during the milestone, but the contract is:

- the Registry exposes each action's enforceable schema centrally;
- Runner separates schema-validated action params from Runner-injected context;
- Runner validates action params before `safe_run` and maps validation failures
  to a clean, redacted `:invalid_params` response;
- no action body runs after central param validation fails; and
- an eval sweep proves valid requests do not regress to `:invalid_params`.

ADR 0064 remains the predecessor for intent slot normalization. ADR 0065 owns
typed, catalog-wide param-contract enforcement.

## Consequences

- Action param semantics become inspectable and enforceable from the same
  central registration path that already carries action capability metadata.
- Malformed or unexpected params fail uniformly before action body execution.
- The migration requires a careful context/param split so system context does
  not accidentally become user-controllable action input.
- Existing action schemas may need tightening or explicit compatibility entries;
  the v0.59 M7 eval sweep is release-blocking for this change.

## Non-Goals

- No new permission class or authority surface.
- No change to confirmation floors.
- No model-granted authority: model output still proposes params only, and
  Security Central remains the authority boundary.
- No automatic rewrite of action behavior outside the central validation seam.
