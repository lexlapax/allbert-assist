# ADR 0064: Central Slot/Param Normalization Seam

Status: Accepted (v0.54 M11; in-scope for v0.54).
Date: 2026-06-16
Related: ADR 0060 (two-stage router + approval-gate separation — produces
`Outcome` slots), ADR 0062 (descriptor lifecycle — `extracted_slots` on the
engine `Decision`), ADR 0006 (Security Central — routing grants no authority).
Successor: v0.58 M7 / ADR 0065 (central action **param-contract** enforcement),
the larger schema-validation follow-on this ADR deliberately scopes out beyond
the router-required-presence guard added during v0.54 M11 validation.

## Context

Intent **slots** — the arguments a router/engine pulls from a user request —
originate from (possibly degraded) model output and become action parameters.
Two producers feed the same consumer:

- **Router path** (ADR 0060): the Stage-2 disambiguator emits `slots` (its
  constrained-output schema declares `slots` as a JSON-object *string*), wrapped
  in `Outcome.execute(action, slots, …)`.
- **Engine path** (ADR 0062): `Descriptor.extract_slots/2` populates
  `Decision.trace_metadata.extracted_slots`.

Both converge in `IntentAgent` when it builds action params, then call
`Actions.Runner.run/3`.

A v0.54 M11 punchlist run (`write_note`, A1) reported a transient
`FunctionClauseError` in `Enum.reduce/3`. A zoom-out over the pipeline found:

1. The crash was **not reproducible** and matched no current code path. Every
   producer already coerced slots to a map, but each did so **independently**
   (`ReqLLMDisambiguator.parse_slots/1`, `Descriptor.extract_slots/2`,
   `Handoff.normalize_map/1`), and each consumer key-mapped slots with its own
   inline helper (`merge_router_slots`/`router_slot_key`,
   `descriptor_params_from_decision`/`normalize_param_key`).
2. The two consumer key policies **differ** and the difference is intentional:
   the router **drops** keys that do not resolve to an existing atom and uses
   `Map.put_new/3` (never overwrites a caller-set param); the engine path is
   **lenient** (keeps unknown string keys) when building a standalone
   descriptor-params map.
3. The `Runner` rejected non-map params but **mislabeled** them as
   `:unknown_action` (`runner.ex`), giving callers the wrong error semantics.

The defensiveness worked but was scattered across five sites with no single
source of truth — inconsistent with the project's "settings central /
registration central" principle.

A later A2/A3 live punchlist pass found a distinct but adjacent failure:
the Stage-2 router could correctly select `write_note` while omitting required
params (`title`/`body`) for underspecified utterances. The action body then
returned an operator-visible `:missing_title` / `:missing_body` error. That is
not a malformed slot payload; it is a missing required-param preflight at the
router execution boundary.

A channel-validation pass also exposed the same general crash class at the
confirmation metadata persistence layer: malformed nested list tails could reach
record serialization and surface `Enum.reduce/3` / `FunctionClauseError` before a
channel approval handoff rendered. v0.54 M11 hardened confirmation record
creation and approval resolution to fold malformed list tails into proper
redacted/stringified lists. That fix is adjacent to this ADR's slot seam rather
than part of `Intent.Slots`, but both close untrusted-shape failures before
operator-visible approval flows.

## Decision

Introduce **one canonical seam**, `AllbertAssist.Intent.Slots`, for the
slot → action-param boundary, and correct the Runner's invalid-params semantics.

### `Intent.Slots`

- `normalize/1` — coerce any slot payload to a map: a map passes through, a
  JSON-object string is decoded, **anything else** (list, scalar, empty/garbage
  string, `nil`) degrades to `%{}`. Single source of truth for the coercion the
  three producers previously duplicated.
- `merge/3` and `to_params/2` — merge normalized slots into a params map under
  an explicit `:key_mode`, preserving both producer policies:
  - `:existing_atom` (router) — keep only existing-atom keys, drop the rest;
    `Map.put_new/3` so caller params win.
  - `:lenient` (engine) — keep unknown string keys; used to build the
    standalone descriptor-params map.

### Wiring

- `ReqLLMDisambiguator.parse_slots/1` → `Slots.normalize/1`.
- `IntentAgent.merge_router_slots/2` → `Slots.merge(params, slots, key_mode: :existing_atom)`.
- `IntentAgent.descriptor_params_from_decision/2` → `Slots.to_params(slots, :lenient)`
  (replaces the M11 local `normalize_extracted_slots` band-aid).

### Runner invalid-params semantics

`Actions.Runner.run/3`'s non-map-params clause now returns a proper
`:invalid_params` (`:non_map`) error response — distinct from
`:unknown_action` — and never embeds the raw payload (it may carry
untrusted/sensitive content). No action body runs on a malformed payload.

### Router required-param presence guard

For router-selected actions only, `IntentAgent.run_router_action/5` now checks
the selected action module's registered schema after context injection and slot
merge, before `Actions.Runner.run/3`. If any `required: true` schema key is
absent or blank, the turn returns `needs_clarification` naming the missing fields
and persists an answerable pending clarification. No action body runs, and no
permission, app-scope, or confirmation decision is changed.

## Consequences

- One place to reason about "what shape do slots have when they become params,"
  and one place to change it.
- Routing still grants no authority: `Intent.Slots` only shapes params; the
  action's own permission/confirmation gate is unchanged (ADR 0006).
- A degraded model payload degrades to "no slots" uniformly instead of risking a
  crash on any future caller that forgets to guard.
- Router-selected actions no longer surface action-body `:missing_*` errors when
  the model selected an action but failed to supply required slots; they clarify
  in-channel instead.
- **Scoped out:** enforcing each action's registered schema centrally beyond
  router required-presence (rejecting unknown or typed-invalid params for *all*
  callers/actions). That requires resolving the injected-context-key split
  (`user_id`/`thread_id`/`session_id`) and an eval sweep across all actions —
  tracked as v0.58 M7 / ADR 0065.
