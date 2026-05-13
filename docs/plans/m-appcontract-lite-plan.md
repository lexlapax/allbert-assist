# Allbert D-Track M-AppContract-Lite: Minimal App Registration Contract

## Purpose

M-AppContract-Lite gives StockSage (and any future Allbert workspace app) a
small public surface to register actions, skills, and navigation with the
Allbert core without reaching through private internals. It must land before
M-D2a scaffolds the StockSage umbrella app.

This is a minimal contract. It does not build the full five-layer app contract
(that is M-AppContract-Full). It gives apps just enough identity to be
registered, supervised, and discoverable.

## Expected Inputs

- M-D1a is complete: string `user_id` exists in runtime; `AllbertAssist.Repo`
  and supervision tree are established.
- `AllbertAssist.Actions.Registry` exists and is the authoritative action
  lookup point.
- `AllbertAssist.Skills.Registry` exists with app-path discovery.
- `AllbertAssist.Application` supervision tree is the host for app children.
- ADR 0015 (app contract and surface DSL) is accepted.

## Scope

### `AllbertAssist.App` Behaviour (Lite)

Seven required callbacks:

```elixir
@callback app_id()       :: atom()
@callback display_name() :: String.t()
@callback version()      :: String.t()
@callback validate(keyword()) :: :ok | {:error, String.t()}
@callback child_spec(keyword()) :: Supervisor.child_spec()
@callback actions()      :: [module()]   # Jido.Action modules to register
@callback skill_paths()  :: [Path.t()]  # priv/skills dirs to add
```

Two optional callbacks:

```elixir
@callback surfaces() :: [AllbertAssist.App.Surface.t()]
# Surface: %{id: atom, title: String.t(), icon: String.t(), path: String.t()}
# Used for workspace shell navigation; shell renders these as nav entries.

@optional_callbacks [surfaces: 0]
```

No `SurfaceProvider`, no `AllbertAssist.Surface` DSL, no AG-UI/A2UI
dependencies. Those belong to M-AppContract-Full.

### `AllbertAssist.App.Registry`

Static registration at application startup; no dynamic runtime mounting:

```elixir
def register(app_module, opts \\ []) do
  with :ok <- app_module.validate(workspace_opts(opts)),
       {:ok, _pid} <- DynamicSupervisor.start_child(
         AllbertAssist.App.Supervisor, app_module.child_spec(workspace_opts(opts))
       ) do
    Enum.each(app_module.actions(),
      &AllbertAssist.Actions.Registry.register(&1, app_id: app_module.app_id()))
    Enum.each(app_module.skill_paths(),
      &AllbertAssist.Skills.Registry.add_path/1)
    Registry.register(__MODULE__, app_module.app_id(), app_module)
    {:ok, app_module.app_id()}
  end
end

def lookup(app_id)         :: {:ok, module()} | {:error, :not_found}
def registered_apps()      :: [module()]
def registered_surfaces()  :: [AllbertAssist.App.Surface.t()]
```

`workspace_opts/1` injects shared config so apps never hardcode global module
names:

```elixir
defp workspace_opts(opts) do
  Keyword.merge([
    repo: AllbertAssist.Repo,
    bus: AllbertAssist.SignalBus,
    pubsub: AllbertAssist.PubSub
  ], opts)
end
```

### `AllbertAssist.Actions.Registry` change

Existing registry gains an optional `app_id:` tag on registered entries. The
intent agent can use this tag to scope action candidate ranking when
`active_app` is set in the session scratchpad. No existing action
registrations are broken; the `app_id` tag defaults to nil for core actions.

### `AllbertAssist.Skills.Registry` change

Existing registry's `add_path/1` already accepts filesystem paths. No change
needed beyond calling it from `App.Registry.register/2`.

### Workspace Shell Navigation

`AllbertAssist.App.Registry.registered_surfaces/0` returns the union of
`surfaces()` from all registered apps. `allbert_assist_web` router can call
this to render workspace navigation entries. Routes remain statically mounted
in the router — navigation entries are display only, not dynamic route
injection.

### Validation At Startup

`validate/1` is called before `DynamicSupervisor.start_child/2`. A validation
failure stops registration and logs a clear error. It does not crash the
supervision tree.

## Non-Goals

- No `AllbertAssist.App.SurfaceProvider` behaviour (M-AppContract-Full).
- No `AllbertAssist.Surface` component DSL (M-AppContract-Full).
- No AG-UI or A2UI dependencies.
- No dynamic route mounting at runtime (routes remain statically configured).
- No app-to-app cross-registration or app dependency chains.
- No permission grants from app registration. Registered actions still run
  through the action runner, Security Central, confirmation workflow, and
  traces. Registration is not authorization.
- No `mix allbert.gen.app` generator (post M-AppContract-Full and v0.17).

## Test Plan

Focused tests should cover:

- A minimal test app implementing the lite behaviour can register successfully.
- `validate/1` failure on startup prevents registration and logs the error;
  the supervision tree continues.
- Registered actions appear in `AllbertAssist.Actions.Registry` tagged with
  `app_id`.
- Registered skill paths appear in `AllbertAssist.Skills.Registry`.
- `App.Registry.registered_apps/0` returns the registered app.
- `App.Registry.registered_surfaces/0` returns the app's navigation surface.
- `App.Registry.lookup(:myapp)` returns the module; lookup for unknown app
  returns `{:error, :not_found}`.
- Existing Allbert core actions and skills are unaffected by app registration.
- A second registration attempt for the same `app_id` fails cleanly.
- Workspace config opts (`repo`, `bus`, `pubsub`) are injected into
  `child_spec/1`; apps do not hardcode global module names.

Final gates (code changes):

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
mix precommit
```

## Definition Of Done

M-AppContract-Lite is done when:

- `AllbertAssist.App` behaviour module exists with the seven required callbacks
  and `surfaces/0` as optional.
- `AllbertAssist.App.Registry` module exists with `register/2`, `lookup/1`,
  `registered_apps/0`, and `registered_surfaces/0`.
- `AllbertAssist.App.Supervisor` (DynamicSupervisor) is started in the
  application supervision tree.
- `AllbertAssist.Actions.Registry` accepts and stores the `app_id:` tag.
- A minimal test app can register and appear in all three lookups.
- Workspace shell nav renders registered app surfaces.
- Existing Allbert core behavior is fully preserved.
- All focused tests and final gates pass.
