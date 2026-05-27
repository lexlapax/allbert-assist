defmodule AllbertAssist.Templates.Patterns.Plugin do
  @moduledoc """
  Reviewed v0.38 source-tree plugin scaffold pattern.

  The rendered output is inert developer source. It does not alter compile
  paths, register the plugin, enable skills, or grant trust.
  """

  @behaviour AllbertAssist.Templates.Pattern

  alias AllbertAssist.Templates.Parameters

  @impl true
  def id, do: "plugin"

  @impl true
  def label, do: "Source-tree plugin"

  @impl true
  def description, do: "Minimal reviewed source-tree plugin scaffold."

  @impl true
  def parameter_schema do
    [
      %{name: "name", type: :string, required: true, min_length: 1, max_length: 64},
      %{
        name: "description",
        type: :string,
        default: "A reviewed Allbert source-tree plugin.",
        max_length: 240
      },
      %{name: "version", type: :string, default: "0.1.0", max_length: 32}
    ]
  end

  @impl true
  def files do
    [
      %{source: "plugin/allbert_plugin.json.tmpl", target: "allbert_plugin.json"},
      %{source: "plugin/README.md.tmpl", target: "README.md"},
      %{source: "plugin/formatter.exs.tmpl", target: ".formatter.exs"},
      %{source: "plugin/plugin.ex.tmpl", target: "lib/{{module_path}}/plugin.ex"},
      %{source: "plugin/skills_readme.md.tmpl", target: "skills/README.md"}
    ]
  end

  @impl true
  def target_shapes, do: ["plugin_manifest", "plugin_module", "skill_root"]

  @impl true
  def live_integration?, do: false

  @impl true
  def validation_profile, do: "developer_scaffold"

  @impl true
  def normalize_params(params) do
    slug = Map.fetch!(params, "slug")
    module_basename = Parameters.module_basename(slug)
    plugin_module = "#{module_basename}.Plugin"
    description = Map.get(params, "description", "")
    display_name = Map.fetch!(params, "display_name")
    version = Map.get(params, "version", "0.1.0")

    {:ok,
     params
     |> Map.put("pattern_id", id())
     |> Map.put("plugin_id", slug)
     |> Map.put("module_path", slug)
     |> Map.put("plugin_module", plugin_module)
     |> Map.put("version", version)
     |> Map.put("json_display_name", Jason.encode!(display_name))
     |> Map.put("json_description", Jason.encode!(description))
     |> Map.put("json_plugin_id", Jason.encode!(slug))
     |> Map.put("json_plugin_module", Jason.encode!(plugin_module))
     |> Map.put("json_version", Jason.encode!(version))
     |> Map.put("description_literal", inspect(description))}
  end
end
