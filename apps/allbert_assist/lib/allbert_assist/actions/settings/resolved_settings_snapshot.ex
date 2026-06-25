defmodule AllbertAssist.Actions.Settings.ResolvedSettingsSnapshot do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "resolved_settings_snapshot",
    description: "Read the resolved Settings Central snapshot for internal web surfaces.",
    category: "settings",
    tags: ["settings", "read_only", "internal", "web"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      settings: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings.Store

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, settings, user_settings} <- Store.resolved_settings() do
      {:ok,
       %{
         message: "Resolved Settings Central snapshot loaded.",
         status: :completed,
         settings: settings,
         actions: [
           action(:completed, permission_decision, %{user_settings?: user_settings != %{}})
         ]
       }}
    else
      false ->
        denied(permission_decision, :permission_denied)

      {:error, reason} ->
        denied(permission_decision, reason)
    end
  end

  defp denied(permission_decision, reason) do
    {:ok,
     %{
       message: "Could not read resolved Settings Central snapshot: #{inspect(reason)}",
       status: :denied,
       error: reason,
       actions: [action(:denied, permission_decision, %{error: reason})]
     }}
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "resolved_settings_snapshot",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      settings_metadata: metadata
    }
  end
end
