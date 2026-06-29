# ADR 0065: Central Action Param-Contract Enforcement

Status: Proposed (v0.59 M7); accepted at v0.59 M7, where the central
param-contract seam ships — matching the v0.59 plan and request-flow. Updated
2026-06-29 (v0.59 readiness review) with the code-grounded blast radius, the
concrete validation mechanism, and the actual context/param split scope.
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

- **Schemas exist but are never enforced.** Action modules declare schemas
  through `use AllbertAssist.Action` / `Jido.Action`, which generates a
  NimbleOptions-backed `validate_params/1`. But `Runner.safe_run/3` calls
  `action_module.run(params, context)` directly (`runner.ex:85`), bypassing
  `Jido.Exec` (which would call `validate_params` before the body). The declared
  schemas are dead weight today.
- **Blast radius (verified 2026-06-29):** ~188 registered actions (48 agent + 140
  internal) plus plugin/dynamic, ~193 modules with `run/2`; only ~47 carry an
  `is_map(params)`-style guard, so ~146 reach `run/2` unguarded. (The earlier
  "72 of 110" figure is a stale v0.54 snapshot; the real sweep is ~1.7x larger.)
- **`schema: []` actions (~40)** declare an empty schema; under NimbleOptions
  strictness an empty schema rejects *any* unspecified key, so turning on
  enforcement flips currently-passing calls unless these get an explicit
  disposition.
- **Atom-vs-string keys.** Model-proposed params often arrive string-keyed while
  schemas are atom-keyed; today actions hand-normalize. Central validation must
  normalize keys *before* validating or it rejects well-formed requests.
- **Context-from-params leakage.** A few actions read *system context* out of
  `params` (`confirm_plan_step.ex:28`, `memory/context.ex:7`,
  `revert_tile_revision.ex:31`); if those keys are validated as schema params they
  become model-controllable — the exact risk the split must prevent.

The result is inconsistent with the project's central-registration posture:
capability, permission, and confirmation metadata resolve centrally, while
param contracts are still enforced action by action.

## Decision

v0.59 M7 adds a central action param-contract seam at the Runner boundary. The
mechanism is concrete (no longer "refined during the milestone"):

- **Reuse the bypassed validator.** The seam calls each action's already-generated
  `validate_params/1` (produced from its `schema:` by `Jido.Action`) inside
  `Runner.safe_run/3`, before `action_module.run/2`. No new validation engine and
  no new Registry plumbing is required — the schema is already exposed per module.
- **Key normalization first.** Params are normalized (string→atom keys) before
  validation so well-formed string-keyed requests are not rejected.
- **The context/param split mostly already exists.** `context` is already a
  separate Runner argument and is never folded into `params` by the Runner
  (`runner_context/3` merges metadata into *context*, not params). The remaining
  split work is narrow: (1) enforce the schema on `params`, and (2) remove the
  context-key reads from `params` in the three named call sites above so system
  context cannot become user-controllable input.
- **`schema: []` disposition.** The ~40 empty-schema actions are handled
  explicitly per action — declared "no params" (reject all keys, intentionally),
  given an open-key/`allow_extra` schema, or added to a reviewed compatibility
  allowlist — not left to default NimbleOptions strictness.
- **Failure shape.** A validation failure maps to a clean, redacted
  `:invalid_params` response (the ADR 0064 shape) before any body runs; that
  response shape is a v1.0 freeze contract (below).
- **Release-blocking eval sweep** over the full ~190-action catalog proves valid
  requests do not regress to `:invalid_params`.

ADR 0064 remains the predecessor for intent slot normalization. ADR 0065 owns
typed, catalog-wide param-contract enforcement.

## Consequences

- Action param semantics become inspectable and enforceable from the same
  central registration path that already carries action capability metadata.
- Malformed or unexpected params fail uniformly before action body execution.
- The context/param split is mostly already in place at the Runner boundary; the
  delta is enforcement plus the three context-in-params cleanups, not a wholesale
  re-plumbing.
- Existing action schemas may need tightening or explicit compatibility entries;
  the v0.59 M7 eval sweep is release-blocking for this change.
- **Freeze readiness.** The seam reshapes two Tier-1-frozen surfaces — the
  Registry's exposed action schema and the Runner `:invalid_params` response
  shape — so it must be delivered freeze-ready in v0.59. The v1.0 plan names both
  in its Tier-1 list; v0.60-v0.63 treat them as additive-only.

## Non-Goals

- No new permission class or authority surface.
- No change to confirmation floors.
- No model-granted authority: model output still proposes params only, and
  Security Central remains the authority boundary.
- No automatic rewrite of action behavior outside the central validation seam.
