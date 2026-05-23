defmodule AllbertAssist.Actions.Plugins.ListPlugins do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_plugins",
    description: "List registered Allbert plugins.",
    category: "plugins",
    tags: ["plugins", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Plugin.Entry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      plugins = PluginRegistry.registered_plugins() |> Enum.map(&Entry.summary/1)
      diagnostics = diagnostics()

      {:ok,
       %{
         message: message(plugins, diagnostics),
         status: :completed,
         plugins: plugins,
         diagnostics: diagnostics,
         actions: [action(:completed, permission_decision, %{plugin_count: length(plugins)})]
       }}
    else
      {:ok,
       %{
         message: "Plugin registry is not available to this request.",
         status: :denied,
         error: :permission_denied,
         actions: [action(:denied, permission_decision, %{error: :permission_denied})]
       }}
    end
  end

  defp diagnostics do
    plugin_diagnostics() ++ action_diagnostics()
  end

  defp plugin_diagnostics do
    PluginRegistry.diagnostics()
    |> Enum.flat_map(fn {plugin_id, diagnostics} ->
      Enum.map(diagnostics, &diagnostic_summary(plugin_id, &1))
    end)
  end

  defp action_diagnostics do
    ActionsRegistry.diagnostics()
    |> Enum.map(fn diagnostic ->
      %{
        plugin_id: Map.get(diagnostic, :plugin_id, "actions"),
        kind: Map.get(diagnostic, :kind, :action_registry_diagnostic),
        severity: Map.get(diagnostic, :severity, :info),
        message: Map.get(diagnostic, :message, "Action registry diagnostic.")
      }
    end)
  end

  defp diagnostic_summary(plugin_id, diagnostic) do
    %{
      plugin_id: plugin_id,
      kind: Map.get(diagnostic, :kind, :plugin_diagnostic),
      severity: Map.get(diagnostic, :severity, :info),
      message: Map.get(diagnostic, :message, "Plugin diagnostic.")
    }
  end

  defp message([], []), do: "No registered plugins."

  defp message(plugins, diagnostics) do
    plugin_lines =
      plugins
      |> Enum.map(fn plugin ->
        "- #{plugin.plugin_id} #{plugin.source} #{plugin.kind} #{plugin.status} #{contributions(plugin)}"
      end)
      |> Enum.join("\n")

    diagnostic_lines =
      diagnostics
      |> Enum.map(fn diagnostic ->
        "- #{diagnostic.plugin_id}: #{diagnostic.kind} #{diagnostic.message}"
      end)
      |> Enum.join("\n")

    case diagnostic_lines do
      "" -> "Registered plugins:\n\n#{plugin_lines}"
      _lines -> "Registered plugins:\n\n#{plugin_lines}\n\nDiagnostics:\n\n#{diagnostic_lines}"
    end
  end

  defp contributions(plugin) do
    [
      "channels=#{plugin.contributions.channels}",
      "skills=#{plugin.contributions.skill_paths}",
      "apps=#{plugin.contributions.apps}",
      "actions=#{plugin.contributions.actions}"
    ]
    |> Enum.join(" ")
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "list_plugins",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      plugin_registry_metadata: metadata
    }
  end
end
