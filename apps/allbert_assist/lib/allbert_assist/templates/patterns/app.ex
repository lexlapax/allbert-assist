defmodule AllbertAssist.Templates.Patterns.App do
  @moduledoc """
  Reviewed v0.38 workspace app scaffold pattern.

  The rendered output documents the app/surface/settings/memory/theme/layout
  contracts while remaining inert until a developer reviews and compiles it.
  """

  @behaviour AllbertAssist.Templates.Pattern

  alias AllbertAssist.Templates.Parameters

  @impl true
  def id, do: "app"

  @impl true
  def label, do: "Workspace app"

  @impl true
  def description, do: "Reviewed plugin-contributed workspace app scaffold."

  @impl true
  def parameter_schema do
    [
      %{name: "name", type: :string, required: true, min_length: 1, max_length: 64},
      %{
        name: "description",
        type: :string,
        default: "A reviewed Allbert workspace app scaffold.",
        max_length: 240
      },
      %{name: "version", type: :string, default: "0.1.0", max_length: 32}
    ]
  end

  @impl true
  def files do
    [
      %{source: "app/allbert_plugin.json.tmpl", target: "allbert_plugin.json"},
      %{source: "app/README.md.tmpl", target: "README.md"},
      %{source: "app/formatter.exs.tmpl", target: ".formatter.exs"},
      %{source: "app/root.ex.tmpl", target: "lib/{{module_path}}.ex"},
      %{source: "app/plugin.ex.tmpl", target: "lib/{{module_path}}/plugin.ex"},
      %{source: "app/app.ex.tmpl", target: "lib/{{module_path}}/app.ex"},
      %{
        source: "app/sample_action.ex.tmpl",
        target: "lib/{{module_path}}/actions/sample_action.ex"
      },
      %{source: "app/intent_descriptor.md.tmpl", target: "priv/intent/{{slug}}.md"},
      %{source: "app/settings_fragment.yml.tmpl", target: "priv/settings/{{slug}}.yml"},
      %{source: "app/memory_namespace.md.tmpl", target: "docs/memory-namespace.md"},
      %{source: "app/objective_canvas_hooks.md.tmpl", target: "docs/objective-canvas-hooks.md"},
      %{source: "app/theme_layout.md.tmpl", target: "docs/theme-layout.md"},
      %{source: "app/skills_readme.md.tmpl", target: "skills/README.md"}
    ]
  end

  @impl true
  def target_shapes do
    [
      "plugin_manifest",
      "app_module",
      "panel_surface",
      "action_stub",
      "settings_fragment",
      "intent_descriptor",
      "memory_namespace",
      "objective_canvas_docs",
      "theme_layout_docs"
    ]
  end

  @impl true
  def live_integration?, do: false

  @impl true
  def validation_profile, do: "developer_scaffold"

  @impl true
  def normalize_params(params) do
    slug = Map.fetch!(params, "slug")
    module_basename = Parameters.module_basename(slug)
    root_module = module_basename
    plugin_module = "#{root_module}.Plugin"
    app_module = "#{root_module}.App"
    action_module = "#{root_module}.Actions.SampleAction"
    action_name = "#{slug}_sample"
    description = Map.get(params, "description", "")
    display_name = Map.fetch!(params, "display_name")
    version = Map.get(params, "version", "0.1.0")

    {:ok,
     params
     |> Map.put("pattern_id", id())
     |> Map.put("plugin_id", slug)
     |> Map.put("module_path", slug)
     |> Map.put("root_module", root_module)
     |> Map.put("plugin_module", plugin_module)
     |> Map.put("app_module", app_module)
     |> Map.put("action_module", action_module)
     |> Map.put("action_name", action_name)
     |> Map.put("panel_surface_id", "#{slug}_panel")
     |> Map.put("version", version)
     |> Map.put("json_display_name", Jason.encode!(display_name))
     |> Map.put("json_description", Jason.encode!(description))
     |> Map.put("json_plugin_id", Jason.encode!(slug))
     |> Map.put("json_plugin_module", Jason.encode!(plugin_module))
     |> Map.put("json_app_module", Jason.encode!(app_module))
     |> Map.put("json_action_module", Jason.encode!(action_module))
     |> Map.put("json_version", Jason.encode!(version))
     |> Map.put("description_literal", inspect(description))
     |> Map.put("display_name_literal", inspect(display_name))}
  end
end
