defmodule AllbertAssist.Actions.Apps.ShowApp do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "show_app",
    description: "Show one registered Allbert workspace app.",
    category: "apps",
    tags: ["apps", "read_only"],
    schema: [app_id: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{app_id: raw_app_id}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    # v1.0.3 M1 (ADR 0086 contract 3 / ADR 0082): honor the internal
    # registry context riding the action context map under `:registry`.
    # Production call sites pass nothing and read the global default.
    app_opts = context |> registry_opts() |> RegistryContext.app_opts()

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, app_id} when not is_nil(app_id) <-
           AppRegistry.normalize_app_id(raw_app_id, app_opts),
         {:ok, entry} <- AppRegistry.lookup(app_id, app_opts) do
      app = detail(entry, app_opts)

      {:ok,
       %{
         message: message(app),
         status: :completed,
         app: app,
         actions: [action(:completed, permission_decision, %{app_id: app_id})]
       }}
    else
      false ->
        denied(raw_app_id, permission_decision, :permission_denied)

      {:ok, nil} ->
        not_found(raw_app_id, permission_decision)

      {:error, :unknown_app} ->
        not_found(raw_app_id, permission_decision)

      {:error, :not_found} ->
        not_found(raw_app_id, permission_decision)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    denied(nil, permission_decision, :invalid_params)
  end

  defp registry_opts(%{registry: registry}) when is_list(registry),
    do: RegistryContext.take(registry)

  defp registry_opts(_context), do: []

  defp detail(entry, app_opts) do
    %{
      app_id: entry.app_id,
      display_name: entry.display_name,
      version: entry.version,
      module: entry.module,
      action_names: entry.actions |> Enum.map(& &1.name()) |> Enum.sort(),
      agent_names: entry |> Map.get(:agents, []) |> Enum.map(&inspect/1) |> Enum.sort(),
      signal_emit_count: length(get_in(entry, [:signals, :emits]) || []),
      signal_subscribe_count: length(get_in(entry, [:signals, :subscribes]) || []),
      skill_paths: entry.skill_paths,
      settings_schema_count: length(Map.get(entry, :settings_schema, [])),
      surfaces: entry.surfaces,
      provider_surfaces: Enum.map(Map.get(entry, :provider_surfaces, []), &surface_summary/1),
      surface_catalog_count: length(Map.get(entry, :surface_catalog, [])),
      diagnostics: diagnostics(entry.app_id, app_opts)
    }
  end

  defp diagnostics(app_id, app_opts) do
    AppRegistry.diagnostics(app_opts)
    |> Map.get(app_id, [])
    |> Enum.map(fn diagnostic ->
      %{
        kind: Map.get(diagnostic, :kind, :app_diagnostic),
        message: Map.get(diagnostic, :message, "App diagnostic.")
      }
    end)
  end

  defp message(app) do
    """
    App #{app.app_id}: #{app.display_name}
    Version: #{app.version}
    Actions: #{line_value(app.action_names)}
    Agents: #{line_value(app.agent_names)}
    Skill paths: #{line_value(app.skill_paths)}
    Signals: emits=#{app.signal_emit_count} subscribes=#{app.signal_subscribe_count}
    Settings schema entries: #{app.settings_schema_count}
    Legacy surfaces: #{surface_value(app.surfaces)}
    Surface provider surfaces: #{surface_value(app.provider_surfaces)}
    Surface catalog entries: #{app.surface_catalog_count}
    """
    |> String.trim()
  end

  defp line_value([]), do: "(none)"
  defp line_value(values), do: Enum.join(values, ", ")

  defp surface_value([]), do: "(none)"

  defp surface_value(surfaces) do
    surfaces
    |> Enum.map(&"#{&1.id}:#{&1.path}")
    |> Enum.join(", ")
  end

  defp surface_summary(surface) do
    %{
      id: surface.id,
      app_id: surface.app_id,
      label: surface.label,
      path: surface.path,
      kind: surface.kind,
      status: surface.status
    }
  end

  defp denied(app_id, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not show app #{inspect(app_id)}: #{inspect(reason)}",
       status: :denied,
       error: reason,
       actions: [action(:denied, permission_decision, %{app_id: app_id, error: reason})]
     }}
  end

  defp not_found(app_id, permission_decision) do
    {:ok,
     %{
       message: "App not found: #{app_id}",
       status: :not_found,
       error: :unknown_app,
       actions: [action(:not_found, permission_decision, %{app_id: app_id, error: :unknown_app})]
     }}
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "show_app",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      app_registry_metadata: metadata
    }
  end
end
