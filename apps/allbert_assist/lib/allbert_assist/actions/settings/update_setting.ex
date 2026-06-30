defmodule AllbertAssist.Actions.Settings.UpdateSetting do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :agent,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "update_setting",
    description: "Update one safe Settings Central key.",
    category: "settings",
    tags: ["settings", "write"],
    schema: [
      key: [type: :string, required: true],
      value: [type: :any, required: true, doc: "Typed Settings Central value."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(%{key: key, value: value}, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, setting} <- Settings.put(key, value, action_context(context, permission_decision)) do
      {:ok,
       %{
         message: "Updated #{setting.key} to #{inspect(setting.value)}.",
         status: :completed,
         setting: setting,
         actions: [action(setting, permission_decision)]
       }}
    else
      false -> denied(key, value, permission_decision, :permission_denied)
      {:error, reason} -> denied(key, value, permission_decision, reason)
    end
  end

  defp denied(key, value, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not update #{key}: #{inspect(reason)}",
       status: :denied,
       actions: [
         %{
           name: "update_setting",
           status: :denied,
           permission: :settings_write,
           permission_decision: permission_decision,
           settings_metadata: %{setting_key: key, value: value, error: reason}
         }
       ]
     }}
  end

  defp action(setting, permission_decision) do
    %{
      name: "update_setting",
      status: :completed,
      permission: :settings_write,
      permission_decision: permission_decision,
      settings_metadata: %{
        setting_key: setting.key,
        source_layer: setting.source,
        audit_path: audit_path(setting.diagnostics)
      }
    }
  end

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

  defp audit_path(diagnostics) do
    diagnostics
    |> Enum.find_value(&Map.get(&1, :audit_path))
  end
end
