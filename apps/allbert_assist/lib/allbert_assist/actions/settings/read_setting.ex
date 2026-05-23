defmodule AllbertAssist.Actions.Settings.ReadSetting do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "read_setting",
    description: "Read one Settings Central value.",
    category: "settings",
    tags: ["settings", "read_only"],
    schema: [key: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(%{key: key}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    case Settings.resolve(key, context) do
      {:ok, setting} ->
        {:ok,
         %{
           message: "#{setting.key}: #{inspect(setting.value)}\nSource: #{setting.source}",
           status: PermissionGate.response_status(permission_decision),
           setting: setting,
           actions: [action(setting, permission_decision)]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "I could not read setting #{key}: #{inspect(reason)}",
           status: :denied,
           actions: [action(%{key: key}, permission_decision, reason)]
         }}
    end
  end

  defp action(setting, permission_decision, error \\ nil) do
    %{
      name: "read_setting",
      status: if(error, do: :denied, else: :completed),
      permission: :read_only,
      permission_decision: permission_decision,
      settings_metadata: %{setting_key: setting.key, error: error}
    }
  end
end
