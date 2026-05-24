defmodule AllbertAssist.Actions.Sandbox.BuildBundle do
  @moduledoc """
  Internal action for building disposable v0.36 sandbox bundles.
  """

  use AllbertAssist.Action,
    permission: :sandbox_trial,
    exposure: :internal,
    execution_mode: :sandbox_trial,
    skill_backed?: false,
    confirmation: :not_required,
    name: "build_sandbox_bundle",
    description: "Build a disposable copy-in/copy-out sandbox bundle.",
    category: "sandbox",
    tags: ["sandbox", "bundle", "internal"],
    schema: [
      project_root: [type: :string, required: true],
      project_paths: [type: {:list, :string}, required: false],
      draft_paths: [type: {:list, :string}, required: false],
      test_paths: [type: {:list, :string}, required: false],
      id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      bundle: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Sandbox
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:sandbox_trial, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, bundle} <- Sandbox.build_bundle(params) do
      summary = Bundle.summary(bundle)

      {:ok,
       %{
         message: "Built sandbox bundle #{bundle.id}.",
         status: :completed,
         permission_decision: permission_decision,
         bundle: summary,
         actions: [action(:completed, permission_decision, %{bundle: summary})]
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
      message: "Sandbox bundle build is denied by Security Central.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{})]
    }
  end

  defp failed(permission_decision, reason) do
    %{
      message: "Could not build sandbox bundle: #{inspect(reason)}",
      status: :denied,
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "build_sandbox_bundle",
      status: status,
      permission: :sandbox_trial,
      permission_decision: permission_decision,
      sandbox_metadata: metadata
    }
  end
end
