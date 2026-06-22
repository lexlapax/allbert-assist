defmodule AllbertAssist.Actions.Operator.SettingGet do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "operator_setting_get",
    description: "Read one redacted setting for operator inspection.",
    category: "operator",
    tags: ["operator", "settings", "read_only"],
    schema: [key: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      setting: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.Operator.Inspection

  @impl true
  def run(params, context) when is_map(params) do
    key = Map.get(params, :key) || Map.get(params, "key")

    Support.read_only(name(), context, fn permission_decision ->
      setting_response(key, context, permission_decision)
    end)
  end

  defp setting_response(key, context, permission_decision) do
    case Inspection.setting(key, context) do
      {:ok, setting} -> setting_success(setting, permission_decision)
      {:error, reason} -> setting_error(key, reason, permission_decision)
    end
  end

  defp setting_success(setting, permission_decision) do
    message = Inspection.render_setting(setting)

    {:ok,
     %{
       message: message,
       model_payload: "Operator setting report.",
       surface_payload: message,
       status: :completed,
       permission_decision: permission_decision,
       setting: setting,
       actions: [
         Support.action(name(), :completed, permission_decision, %{key: setting.key})
       ]
     }}
  end

  defp setting_error(key, reason, permission_decision) do
    message = Inspection.render_setting_error(key, reason)
    status = if reason == :not_found, do: :not_found, else: :error

    {:ok,
     %{
       message: message,
       model_payload: "Operator setting request failed.",
       surface_payload: message,
       status: status,
       permission_decision: permission_decision,
       actions: [
         Support.action(name(), status, permission_decision, %{error: reason})
       ]
     }}
  end
end
