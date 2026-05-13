# Allbert D-Track M-AppContract-Full: Full App Contract And Surface DSL

## Status

Planning. Full spec lives in `docs/plans/aiworkspace-plan.md` §5 and §6 and
in `docs/adr/0015-allbert-app-contract-and-surface-dsl.md`. This plan file
will be expanded to implementation-ready detail when M-D2a proves the lite
contract in practice.

## Purpose

M-AppContract-Full matures the minimal app registration contract into the
complete five-layer `AllbertAssist.App` behaviour and provides the
`AllbertAssist.Surface` component DSL that allbert core v0.17 consumes for
canvas work. StockSage is the first proving app.

This milestone is the one hard prerequisite for v0.17 canvas implementation.
v0.17 cannot start until M-AppContract-Full is done.

## Hard Prerequisites

- M-AppContract-Lite complete and proven by at least M-D2a usage.
- M-D2a complete (StockSage domain exists as a real app proving the contract).
- v0.15 intent enrichment landed (M-AppContract-Full extends the routing
  inputs v0.15 established).

## Sequence

M-AppContract-Full runs parallel to v0.15–v0.16. It must complete before
v0.17 canvas work starts.

## Scope (Five Contract Layers)

**Layer 1 — Identity and OTP:**
`app_id/0`, `display_name/0`, `version/0`, `validate/1` (called before children
start; misconfiguration fails loudly), `child_spec/1` (receives workspace opts
so apps never hardcode global modules).

**Layer 2 — Agents, Actions, Signals:**
`actions/0` (Jido.Action modules registered in global registry tagged with
`app_id`), `agents/0` (Jido.Agent modules), `signal_emits/0` (declarative;
for documentation and permission-gate checks), `signal_subscribes/0` (wires
bus subscriptions on registration).

**Layer 3 — Skills:**
`skill_paths/0` — filesystem paths added to `AllbertAssist.Skills.Registry`
on registration.

**Layer 4 — UI Surface:**
`surfaces/0` (navigation entries), `live_views/0` (path → module pairs
mounted at startup), `router_scope/0` (optional sub-router for apps needing
their own pipeline).

**Layer 5 — Data and Settings:**
`settings_schema/0` (NimbleOptions-style declarations validated at startup),
`memory_namespaces/0` (allbert memory categories this app may write to).

### New Modules

```
AllbertAssist.App                 # full behaviour (extends lite)
AllbertAssist.App.Registry        # Elixir Registry + DynamicSupervisor (extends lite)
AllbertAssist.App.SurfaceProvider # secondary behaviour for interactive surfaces
AllbertAssist.Surface             # native component DSL
AllbertAssist.Surface.Encoder     # optional: converts to A2UI JSON (not used by LiveView)
```

### `AllbertAssist.Surface` Component DSL

Elixir terms, not JSON. Validated against a known catalog; model output cannot
inject arbitrary node shapes:

```elixir
@type node ::
    {:text,    attrs(), String.t()}
  | {:heading, attrs(), String.t()}
  | {:image,   attrs(), String.t()}
  | {:button,  attrs(), String.t()}
  | {:list,    attrs(), [node()]}
  | {:table,   attrs(), %{columns: list(), rows: list()}}
  | {:chart,   attrs(), %{type: :line | :bar | :candle, data: list()}}
  | {:form,    attrs(), [node()]}
  | {:card,    attrs(), [node()]}
  | {:badge,   attrs(), String.t()}
  | {:custom,  atom(), map()}        # registered catalog entry only
```

### `AllbertAssist.App.SurfaceProvider` Behaviour

```elixir
@callback init(surface_id()) :: {:ok, surface_state()} | {:error, term()}
@callback render(surface_id(), surface_state()) :: AllbertAssist.Surface.node()
@callback handle_action(surface_id(), action :: map()) ::
    {:signal, Jido.Signal.t(), surface_state()} | {:noreply, surface_state()}
```

`handle_action/2` must return a Jido signal; state changes go through the
signal bus, not direct GenServer mutation.

### Deliverables

- `AllbertAssist.App` behaviour with all five layers and optional callbacks.
- `AllbertAssist.App.Registry` updated to wire signal subscriptions, settings
  validation, and memory namespace registration.
- `AllbertAssist.App.SurfaceProvider` behaviour.
- `AllbertAssist.Surface` DSL module with catalog validation.
- `AllbertAssist.Surface.Encoder.to_a2ui/1` (optional bridge; not called by
  the Phoenix web UI path).
- `mix allbert.validate_app MyApp` mix task.
- `StockSage.App` fully implements all five layers (proves the contract).
- ADR 0015 transitions from Proposed to Accepted.
- `docs/how-to-create-an-allbert-app.md` developer guide (StockSage as worked
  example).

## Non-Goals

- No AG-UI or A2UI package dependency in the local web path.
- No `mix allbert.gen.app` generator (after M-D3b proves the contract).
- No dynamic runtime route mounting from untrusted sources.
- No canvas implementation (that is v0.17's job, consuming these contracts).
- No permission grants from app registration; action runner and Security
  Central remain the enforcement points.

## Definition Of Done (high level — detail added pre-implementation)

- `mix allbert.validate_app StockSage.App` passes.
- `AllbertAssist.App.Registry.registered_apps/0` returns `[:stocksage]` at
  runtime.
- ADR 0015 is Accepted.
- `docs/how-to-create-an-allbert-app.md` is committed.
- v0.17 canvas work can begin using these contracts.
