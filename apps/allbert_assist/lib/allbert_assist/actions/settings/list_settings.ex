defmodule AllbertAssist.Actions.Settings.ListSettings do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_settings",
    description: "List Settings Central values with source metadata.",
    category: "settings",
    tags: ["settings", "read_only"],
    schema: [namespace: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:ok, settings} <- Settings.list(namespace: Map.get(params, :namespace)) do
      {:ok,
       %{
         message: message(settings),
         status: PermissionGate.response_status(permission_decision),
         settings: settings,
         actions: [action(settings, permission_decision)]
       }}
    end
  end

  defp message(settings) do
    rendered =
      settings
      |> Enum.map(&"- #{&1.key}: #{inspect(&1.value)} (#{&1.source})")
      |> Enum.join("\n")

    "Settings Central values:\n\n#{rendered}"
  end

  defp action(settings, permission_decision) do
    %{
      name: "list_settings",
      status: :completed,
      permission: :read_only,
      permission_decision: permission_decision,
      settings_metadata: %{count: length(settings)}
    }
  end
end
