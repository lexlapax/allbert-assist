defmodule AllbertAssist.Actions.Apps.ShowApp do
  @moduledoc false

  use Jido.Action,
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
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{app_id: raw_app_id}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, app_id} when not is_nil(app_id) <- AppRegistry.normalize_app_id(raw_app_id),
         {:ok, entry} <- AppRegistry.lookup(app_id) do
      app = detail(entry)

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

  defp detail(entry) do
    %{
      app_id: entry.app_id,
      display_name: entry.display_name,
      version: entry.version,
      module: entry.module,
      action_names: Enum.map(entry.actions, & &1.name()),
      skill_paths: entry.skill_paths,
      surfaces: entry.surfaces,
      diagnostics: diagnostics(entry.app_id)
    }
  end

  defp diagnostics(app_id) do
    AppRegistry.diagnostics()
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
    Skill paths: #{line_value(app.skill_paths)}
    Surfaces: #{surface_value(app.surfaces)}
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
