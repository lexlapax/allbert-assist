defmodule AllbertAssist.Actions.DynamicPlugins.DisableLiveLoader do
  @moduledoc """
  Internal emergency action for disabling v0.37 live dynamic integration.
  """

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "disable_dynamic_live_loader",
    description: "Disable the dynamic live loader and clear live dynamic action registrations.",
    category: "dynamic_plugins",
    tags: ["dynamic-plugins", "loader", "disable", "internal"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, result} <- DynamicPlugins.disable_live_loader(context: context) do
      {:ok,
       %{
         message: "Dynamic live loader disabled.",
         status: :completed,
         permission_decision: permission_decision,
         dynamic_plugin_metadata: result,
         actions: [action(:completed, permission_decision, result)]
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
       message: "Could not disable dynamic live loader: #{inspect(reason)}",
       status: :denied,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, %{error: reason})]
     }}
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "disable_dynamic_live_loader",
      status: status,
      permission: :settings_write,
      permission_decision: permission_decision,
      dynamic_plugin_metadata: metadata
    }
  end
end
