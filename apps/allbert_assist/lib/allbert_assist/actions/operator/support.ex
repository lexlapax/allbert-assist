defmodule AllbertAssist.Actions.Operator.Support do
  @moduledoc false

  alias AllbertAssist.Security.PermissionGate

  @spec read_only(String.t(), map(), (PermissionGate.decision() -> {:ok, map()})) ::
          {:ok, map()}
  def read_only(action_name, context, on_allowed) when is_function(on_allowed, 1) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      on_allowed.(permission_decision)
    else
      {:ok,
       %{
         message: "Operator inspection denied by Security Central.",
         status: :denied,
         permission_decision: permission_decision,
         actions: [action(action_name, :denied, permission_decision)]
       }}
    end
  end

  @spec action(String.t(), atom(), PermissionGate.decision(), map()) :: map()
  def action(action_name, status, permission_decision, metadata \\ %{}) do
    Map.merge(
      %{
        name: action_name,
        status: status,
        permission: :read_only,
        permission_decision: permission_decision
      },
      metadata
    )
  end
end
