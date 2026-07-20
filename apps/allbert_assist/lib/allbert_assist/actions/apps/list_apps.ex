defmodule AllbertAssist.Actions.Apps.ListApps do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_apps",
    description: "List registered Allbert workspace apps.",
    category: "apps",
    tags: ["apps", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      # v1.0.3 M1 (ADR 0086 contract 3 / ADR 0082): honor the internal
      # registry context riding the action context map under `:registry`.
      # Production call sites pass nothing and read the global default.
      app_opts = context |> registry_opts() |> RegistryContext.app_opts()
      apps = Enum.map(AppRegistry.registered_apps(app_opts), &summary/1)
      diagnostics = diagnostics(app_opts)

      {:ok,
       %{
         message: message(apps, diagnostics),
         status: :completed,
         apps: apps,
         diagnostics: diagnostics,
         actions: [action(:completed, permission_decision, %{app_count: length(apps)})]
       }}
    else
      {:ok,
       %{
         message: "App registry is not available to this request.",
         status: :denied,
         error: :permission_denied,
         actions: [action(:denied, permission_decision, %{error: :permission_denied})]
       }}
    end
  end

  defp summary(entry) do
    %{
      app_id: entry.app_id,
      display_name: entry.display_name,
      version: entry.version,
      agent_count: length(Map.get(entry, :agents, [])),
      action_count: length(entry.actions),
      signal_emit_count: length(get_in(entry, [:signals, :emits]) || []),
      signal_subscribe_count: length(get_in(entry, [:signals, :subscribes]) || []),
      skill_path_count: length(entry.skill_paths),
      settings_schema_count: length(Map.get(entry, :settings_schema, [])),
      surface_count: length(entry.surfaces) + length(Map.get(entry, :provider_surfaces, []))
    }
  end

  defp registry_opts(%{registry: registry}) when is_list(registry),
    do: RegistryContext.take(registry)

  defp registry_opts(_context), do: []

  defp diagnostics(app_opts) do
    AppRegistry.diagnostics(app_opts)
    |> Enum.flat_map(fn {app_id, diagnostics} ->
      Enum.map(diagnostics, &diagnostic_summary(app_id, &1))
    end)
  end

  defp diagnostic_summary(app_id, diagnostic) do
    %{
      app_id: app_id,
      kind: Map.get(diagnostic, :kind, :app_diagnostic),
      message: Map.get(diagnostic, :message, "App diagnostic.")
    }
  end

  defp message([], []), do: "No registered apps."

  defp message(apps, diagnostics) do
    app_lines =
      apps
      |> Enum.map(fn app ->
        "- #{app.app_id} (#{app.display_name}) v#{app.version} actions=#{app.action_count} skills=#{app.skill_path_count} surfaces=#{app.surface_count}"
      end)
      |> Enum.join("\n")

    diagnostic_lines =
      diagnostics
      |> Enum.map(fn diagnostic ->
        "- #{diagnostic.app_id}: #{diagnostic.kind} #{diagnostic.message}"
      end)
      |> Enum.join("\n")

    case diagnostic_lines do
      "" -> "Registered apps:\n\n#{app_lines}"
      _lines -> "Registered apps:\n\n#{app_lines}\n\nDiagnostics:\n\n#{diagnostic_lines}"
    end
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "list_apps",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      app_registry_metadata: metadata
    }
  end
end
