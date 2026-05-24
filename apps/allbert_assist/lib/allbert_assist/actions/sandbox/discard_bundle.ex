defmodule AllbertAssist.Actions.Sandbox.DiscardBundle do
  @moduledoc """
  Internal action for discarding v0.36 sandbox bundles.
  """

  use AllbertAssist.Action,
    permission: :sandbox_trial,
    exposure: :internal,
    execution_mode: :sandbox_trial,
    skill_backed?: false,
    confirmation: :not_required,
    name: "discard_sandbox_bundle",
    description: "Discard a disposable sandbox bundle root.",
    category: "sandbox",
    tags: ["sandbox", "cleanup", "internal"],
    schema: [root: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Sandbox
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:sandbox_trial, context)

    with true <- PermissionGate.allowed?(permission_decision),
         :ok <- Sandbox.cleanup(Map.fetch!(params, :root)) do
      {:ok,
       %{
         message: "Discarded sandbox bundle.",
         status: :completed,
         permission_decision: permission_decision,
         actions: [action(:completed, permission_decision, %{root: Map.fetch!(params, :root)})]
       }}
    else
      false ->
        {:ok, denied(permission_decision)}

      {:error, reason} ->
        {:ok, failed(permission_decision, reason)}
    end
  end

  defp denied(permission_decision) do
    %{
      message: "Sandbox bundle cleanup is denied by Security Central.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{})]
    }
  end

  defp failed(permission_decision, reason) do
    %{
      message: "Could not discard sandbox bundle: #{inspect(reason)}",
      status: :denied,
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "discard_sandbox_bundle",
      status: status,
      permission: :sandbox_trial,
      permission_decision: permission_decision,
      sandbox_metadata: metadata
    }
  end
end
