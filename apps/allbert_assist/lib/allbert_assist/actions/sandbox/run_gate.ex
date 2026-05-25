defmodule AllbertAssist.Actions.Sandbox.RunGate do
  @moduledoc """
  Internal action for running reviewed v0.36 sandbox gate profiles.
  """

  use AllbertAssist.Action,
    permission: :sandbox_trial,
    exposure: :internal,
    execution_mode: :sandbox_trial,
    skill_backed?: false,
    confirmation: :not_required,
    name: "run_sandbox_gate",
    description: "Run reviewed sandbox gate profiles and return a report.",
    category: "sandbox",
    tags: ["sandbox", "gate", "internal"],
    schema: [
      bundle: [type: :map, required: true],
      profiles: [type: {:list, :atom}, required: false],
      focused_test_paths: [type: {:list, :string}, required: false],
      security_eval_paths: [type: {:list, :string}, required: false]
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
         {:ok, report} <- Sandbox.run_gate(bundle, gate_opts(params, context)) do
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

  defp gate_opts(params, context) do
    params
    |> Map.take([:profiles, :focused_test_paths, :security_eval_paths])
    |> Map.put(:operator_id, operator_id(context))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp operator_id(context) do
    Map.get(context, :operator_id) || Map.get(context, "operator_id") ||
      Map.get(context, :user_id) || Map.get(context, "user_id") ||
      Map.get(context, :actor) || Map.get(context, "actor")
  end

  defp completed(permission_decision, %Report{} = report) do
    report_map = Report.to_map(report)

    %{
      message: "Sandbox gate finished with status #{report.status}.",
      status: report.status,
      permission_decision: permission_decision,
      report: report_map,
      actions: [action(report.status, permission_decision, %{report: report_map})]
    }
  end

  defp denied(permission_decision) do
    %{
      message: "Sandbox gate is denied by Security Central.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{})]
    }
  end

  defp failed(permission_decision, reason) do
    %{
      message: "Could not run sandbox gate: #{inspect(reason)}",
      status: :denied,
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "run_sandbox_gate",
      status: status,
      permission: :sandbox_trial,
      permission_decision: permission_decision,
      sandbox_metadata: metadata
    }
  end
end
