# How To Create An Allbert App

Allbert apps are local, compiled Elixir modules that contribute contract
metadata to the Allbert runtime. They do not gain authority by registering.
Actions still run through `AllbertAssist.Actions.Runner`, Security Central,
confirmations, traces, and audits.

This guide is for reviewed source-tree apps and plugin-contributed apps that
are compiled with the project. v0.37 generated drafts are different: they live
under Allbert Home, are not scanned by ordinary plugin discovery, must pass the
v0.36 sandbox gate, and may integrate live only through
`AllbertAssist.DynamicPlugins.Loader` after Security Central confirmation. For
generated app work, use
`docs/developer/dynamic-plugin-drafts.md` instead of copying the source-tree
workflow below.

## Worked Reference: `allbert.notes_files`

v0.42 ships `./plugins/allbert.notes_files/` as the smallest complete native
reference plugin. Read it before creating a hand-written app/plugin:

- `AllbertNotesFiles.Plugin` contributes one app, three actions, and two skill
  roots through the normal shipped-plugin discovery path.
- `AllbertNotesFiles.App` uses `AllbertAssist.App.SurfaceProvider`, declares the
  `:notes_files` app id, registers the non-writable `:notes_files` memory
  namespace, exposes list/detail workspace panels, and delegates settings to a
  small `Settings.Fragment`.
- `search_notes` and `read_note` are `:read_only` actions that emit `file://`
  `read_local_path` refs as provenance/audit metadata; actual file access is bounded by
  `PermissionGate` plus notes-root/path/extension/size checks.
- `write_note` uses `:notes_file_write`, creates a durable confirmation with a
  `write_local_path` provenance ref, and writes only after Approval Handoff resumes it.
- The plugin deliberately does not auto-promote note files into memory; memory
  promotion remains a separate confirmed memory action.

The important pattern is not the notes domain. It is the boundary shape:
registration is inert, actions declare capability metadata, settings live under
`apps.<app_id>.*`, surfaces are declarative, and effectful work still goes through
Runner, Security Central, policy-specific bounds, provenance, and confirmations. For
notes/files specifically, Resource Access refs describe touched files; they are not the
grant check at the `File.*` boundary. v0.65 records that distinction while adding the
product-facing `allbert admin notes set-root PATH` and `workspace:notes` surfaces.

## Recommended Path: `mix allbert.gen.app`

The primary developer path is the generator. It writes the inert reviewed
skeleton under `--target` and is non-destructive by default:

```sh
mix allbert.gen.app my_app
# writes ./plugins/my_app/ (default --target)

mix allbert.gen.app my_app --target ./plugins/my_app
# explicit target; identical behavior

mix allbert.gen.app my_app --force
# overwrite an existing root only after confirming the preview/diff

mix allbert.gen.app my_app --smoke
# disposable validation output under $ALLBERT_HOME/template-smoke/my_app/
```

v0.38 also ships `mix allbert.gen.plugin` for source-tree plugin scaffolds,
`mix allbert.gen.tool` for LLM-tool action scaffolds, and
`mix allbert.gen.flow` for scheduled-flow and objective-workflow scaffolds.
Set `ALLBERT_TEMPLATE_SMOKE=1` during manual validation to apply the same
disposable Allbert Home target to every generator command without adding
`--smoke` each time.
Generated output is **inert**: no compile path change, trust grant, permission
grant, route addition, skill enablement, or live registration. Generated
theme/snippet/layout stubs respect the v0.34/v0.35 constraints — they document
the contracts and stay disabled by default. Path traversal, oversize outputs,
and existing-root overwrites without `--force` are denied. After the generated
app module is on the project compile path, run `mix allbert.validate_app
my_app` (app id) or `mix allbert.validate_app MyApp.App` (module) to confirm
the scaffold validates on first run. The v0.38 task path resolves loaded app
modules by safe app id without creating atoms from raw input.

The detailed `TemplatePattern` behaviour, parameter schema rules, deterministic
rendering contract, and per-pattern `live_integration?` declarations live in
`docs/developer/template-patterns.md`. The hand-written source below remains
the minimal reviewed app shape; the
generator produces a fuller plugin-contributed scaffold with panel, settings,
intent, memory, objective/canvas, and theme/layout stubs. The generator is an
accelerator, not a runtime authority.

## Minimal Plugin-Contributed App

```elixir
defmodule MyPlugin.App do
  use AllbertAssist.App
  use AllbertAssist.App.SurfaceProvider

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node

  @impl true
  def app_id, do: :my_app

  @impl true
  def display_name, do: "My App"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def actions, do: [MyPlugin.Actions.SayHello]

  @impl true
  def agents, do: []

  @impl true
  def signals do
    %{emits: ["my_app.example.started"], subscribes: []}
  end

  @impl true
  def skill_paths do
    [Path.expand("../skills", __DIR__)]
  end

  @impl true
  def settings_schema do
    [
      %{
        key: "apps.my_app.enabled",
        type: :boolean,
        default: false,
        description: "Enable My App.",
        secret?: false
      }
    ]
  end

  @impl true
  def surfaces do
    [
      %Surface{
        id: :home,
        app_id: :my_app,
        label: "My App",
        path: "/my_app",
        kind: :route,
        status: :placeholder,
        nodes: [%Node{id: "root", component: :route}],
        fallback_text: "My App is available at /my_app."
      }
    ]
  end

  def surface_catalog do
    [%{component: :route, allowed_props: [], allowed_bindings: []}]
  end
end
```

The plugin module then contributes the app:

```elixir
defmodule MyPlugin do
  use AllbertAssist.Plugin

  def plugin_id, do: "example.my_plugin"
  def display_name, do: "Example My Plugin"
  def version, do: "0.1.0"
  def validate(_opts), do: :ok
  def apps, do: [MyPlugin.App]
end
```

## Callback Summary

`AllbertAssist.App` callbacks:

- `app_id/0`, `display_name/0`, `version/0`: identity metadata.
- `validate/1`: app-owned startup validation.
- `child_spec/1`: optional supervised child process; defaults to `:ignore`.
- `agents/0`: declared agent modules.
- `actions/0`: registered Jido action modules.
- `signals/0`: declared emitted/subscribed signal topics.
- `skill_paths/0`: app-owned Agent Skill roots.
- `settings_schema/0`: Settings Central schema entries under
  `apps.<app_id>.*`.
- `surfaces/0`: legacy navigation summaries, or provider surfaces when the
  module uses `AllbertAssist.App.SurfaceProvider`.

`AllbertAssist.App.SurfaceProvider` callbacks:

- `surfaces/0`: validated `AllbertAssist.Surface` declarations.
- `surface_catalog/0`: allowed component catalog entries.
- `fallback_surface/1`: optional text fallback; defaults to
  `{:error, :not_found}`.

Memory namespace registration is not part of v0.18. It is deferred to v0.29
(formerly v0.27 before the project-direction rethink renumber).

## Validate The App

After the module is compiled:

```sh
mix allbert.validate_app MyPlugin.App
```

Expected output includes the app id, version, action count, skill path count,
agent count, settings schema count, signal counts, and surface ids/paths. The
task prints summaries only; it does not dump raw node trees or secrets.

Reviewed source-tree apps can add route surfaces when the host router has a
reviewed route for them. v0.37 generated app drafts cannot add Phoenix routes,
custom LiveViews, custom components, or HEEx. They can contribute only validated
panel/destination data through the dynamic loader.
