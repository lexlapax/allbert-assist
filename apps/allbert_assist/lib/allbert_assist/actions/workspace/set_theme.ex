defmodule AllbertAssist.Actions.Workspace.SetTheme do
  @moduledoc "Set the workspace theme through the registered action boundary."

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "set_workspace_theme",
    description: "Set the operator workspace theme preference.",
    category: "workspace",
    tags: ["workspace", "settings", "write"],
    schema: [
      theme: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    theme = field(params, :theme)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         theme when is_binary(theme) and theme != "" <- theme,
         {:ok, setting} <-
           Settings.put("workspace.theme", theme, action_context(context, permission_decision)) do
      {:ok, completed(setting, permission_decision)}
    else
      {:allowed, false} ->
        {:ok, denied(theme, permission_decision, :permission_denied)}

      nil ->
        {:ok, denied(theme, permission_decision, :missing_theme)}

      "" ->
        {:ok, denied(theme, permission_decision, :missing_theme)}

      {:error, reason} ->
        {:ok, denied(theme, permission_decision, reason)}

      _other ->
        {:ok, denied(theme, permission_decision, :invalid_theme)}
    end
  end

  def run(params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    {:ok, denied(field(params, :theme), permission_decision, :invalid_params)}
  end

  defp completed(setting, permission_decision) do
    %{
      message: "Updated workspace theme to #{setting.value}.",
      status: :completed,
      theme: setting.value,
      setting: setting,
      permission_decision: permission_decision,
      actions: [
        action(:completed, permission_decision, %{
          setting_key: setting.key,
          theme: setting.value,
          source_layer: setting.source
        })
      ]
    }
  end

  defp denied(theme, permission_decision, reason) do
    %{
      message: "Could not update workspace theme: #{inspect(reason)}",
      status: denied_status(permission_decision),
      reason: reason,
      permission_decision: permission_decision,
      actions: [
        action(:denied, permission_decision, %{
          setting_key: "workspace.theme",
          theme: theme,
          error: reason
        })
      ]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "set_workspace_theme",
      status: status,
      permission: :settings_write,
      permission_decision: permission_decision,
      workspace_metadata: metadata
    }
  end

  defp denied_status(%{decision: :allowed}), do: :denied
  defp denied_status(permission_decision), do: PermissionGate.response_status(permission_decision)

  defp action_context(context, permission_decision) do
    request_context = Map.get(context, :request, context)

    request_context
    |> Map.take([:actor, :operator_id, :channel, :input_signal_id])
    |> Map.new(fn
      {:operator_id, value} -> {:actor, value}
      {:input_signal_id, value} -> {:source_signal_id, value}
      other -> other
    end)
    |> Map.put(:permission_decision, permission_decision)
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
