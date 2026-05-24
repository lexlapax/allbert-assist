defmodule AllbertAssist.Actions.Sandbox.RunCommand do
  @moduledoc """
  Internal action for running one v0.36 sandbox command.
  """

  use AllbertAssist.Action,
    permission: :sandbox_trial,
    exposure: :internal,
    execution_mode: :sandbox_trial,
    skill_backed?: false,
    confirmation: :not_required,
    name: "run_sandbox_command",
    description: "Run one explicit sandbox CommandSpec and return a report.",
    category: "sandbox",
    tags: ["sandbox", "command", "internal"],
    schema: [
      bundle: [type: :map, required: true],
      command: [type: :map, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      report: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Sandbox
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.Report
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:sandbox_trial, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, bundle} <- fetch_bundle(params),
         {:ok, report} <- Sandbox.run_command(bundle, Map.fetch!(params, :command)) do
      {:ok, completed(permission_decision, report)}
    else
      false ->
        {:ok, denied(permission_decision)}

      {:error, reason} ->
        {:ok, failed(permission_decision, reason)}
    end
  end

  defp fetch_bundle(%{bundle: %Bundle{} = bundle}), do: {:ok, bundle}
  defp fetch_bundle(_params), do: {:error, :bundle_required}

  defp completed(permission_decision, %Report{} = report) do
    report_map = Report.to_map(report)

    %{
      message: "Sandbox command finished with status #{report.status}.",
      status: report.status,
      permission_decision: permission_decision,
      report: report_map,
      actions: [action(report.status, permission_decision, %{report: report_map})]
    }
  end

  defp denied(permission_decision) do
    %{
      message: "Sandbox command is denied by Security Central.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{})]
    }
  end

  defp failed(permission_decision, reason) do
    %{
      message: "Could not run sandbox command: #{inspect(reason)}",
      status: :denied,
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "run_sandbox_command",
      status: status,
      permission: :sandbox_trial,
      permission_decision: permission_decision,
      sandbox_metadata: metadata
    }
  end
end
