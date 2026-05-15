defmodule AllbertAssist.Actions.Plugins.ShowPlugin do
  @moduledoc false

  use Jido.Action,
    name: "show_plugin",
    description: "Show one registered Allbert plugin.",
    category: "plugins",
    tags: ["plugins", "read_only"],
    schema: [plugin_id: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{plugin_id: plugin_id}, context) when is_binary(plugin_id) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, entry} <- PluginRegistry.lookup(plugin_id) do
      plugin = detail(entry)

      {:ok,
       %{
         message: message(plugin),
         status: :completed,
         plugin: plugin,
         actions: [action(:completed, permission_decision, %{plugin_id: plugin_id})]
       }}
    else
      false ->
        denied(plugin_id, permission_decision, :permission_denied)

      {:error, :not_found} ->
        not_found(plugin_id, permission_decision)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    denied(nil, permission_decision, :invalid_params)
  end

  defp detail(entry) do
    %{
      plugin_id: entry.plugin_id,
      display_name: entry.display_name,
      version: entry.version,
      kind: entry.kind,
      source: entry.source,
      status: entry.status,
      trust_status: entry.trust_status,
      module: entry.module,
      root_path: entry.root_path,
      manifest_path: entry.manifest_path,
      channels: Enum.map(entry.channels, &Map.get(&1, :channel_id)),
      apps: Enum.map(entry.apps, &inspect/1),
      actions: entry.actions |> Enum.map(& &1.name()) |> Enum.sort(),
      skill_paths: entry.skill_paths,
      settings_schema_count: length(entry.settings_schema),
      child_spec?: entry.children != :ignore,
      diagnostics: diagnostics(entry.plugin_id)
    }
  end

  defp diagnostics(plugin_id) do
    plugin_diagnostics =
      PluginRegistry.diagnostics()
      |> Map.get(plugin_id, [])
      |> Enum.map(fn diagnostic ->
        %{
          kind: Map.get(diagnostic, :kind, :plugin_diagnostic),
          severity: Map.get(diagnostic, :severity, :info),
          message: Map.get(diagnostic, :message, "Plugin diagnostic.")
        }
      end)

    action_diagnostics =
      ActionsRegistry.diagnostics()
      |> Enum.filter(&(Map.get(&1, :plugin_id) == plugin_id))
      |> Enum.map(fn diagnostic ->
        %{
          kind: Map.get(diagnostic, :kind, :action_registry_diagnostic),
          severity: Map.get(diagnostic, :severity, :info),
          message: Map.get(diagnostic, :message, "Action registry diagnostic.")
        }
      end)

    plugin_diagnostics ++ action_diagnostics
  end

  defp message(plugin) do
    """
    Plugin #{plugin.plugin_id}: #{plugin.display_name}
    Version: #{plugin.version}
    Source: #{plugin.source}
    Status: #{plugin.status}
    Trust: #{plugin.trust_status}
    Channels: #{line_value(plugin.channels)}
    Actions: #{line_value(plugin.actions)}
    Apps: #{line_value(plugin.apps)}
    Skill paths: #{line_value(plugin.skill_paths)}
    Settings schema entries: #{plugin.settings_schema_count}
    Diagnostics: #{diagnostic_value(plugin.diagnostics)}
    """
    |> String.trim()
  end

  defp line_value([]), do: "(none)"
  defp line_value(values), do: Enum.join(values, ", ")

  defp diagnostic_value([]), do: "none"

  defp diagnostic_value(diagnostics) do
    diagnostics
    |> Enum.map(&"#{&1.kind} #{&1.message}")
    |> Enum.join(", ")
  end

  defp denied(plugin_id, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not show plugin #{inspect(plugin_id)}: #{inspect(reason)}",
       status: :denied,
       error: reason,
       actions: [action(:denied, permission_decision, %{plugin_id: plugin_id, error: reason})]
     }}
  end

  defp not_found(plugin_id, permission_decision) do
    {:ok,
     %{
       message: "Plugin not found: #{plugin_id}",
       status: :not_found,
       error: :unknown_plugin,
       actions: [
         action(:not_found, permission_decision, %{plugin_id: plugin_id, error: :unknown_plugin})
       ]
     }}
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "show_plugin",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      plugin_registry_metadata: metadata
    }
  end
end
