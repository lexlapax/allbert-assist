defmodule AllbertAssist.Actions.Sandbox.Doctor do
  @moduledoc """
  Internal action for reading v0.36 sandbox readiness.
  """

  use AllbertAssist.Action,
    permission: :sandbox_trial,
    exposure: :internal,
    execution_mode: :sandbox_trial,
    skill_backed?: false,
    confirmation: :not_required,
    name: "sandbox_doctor",
    description: "Inspect v0.36 sandbox settings and backend readiness.",
    category: "sandbox",
    tags: ["sandbox", "doctor", "internal"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      doctor: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Sandbox
  alias AllbertAssist.Sandbox.DoctorReport
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:sandbox_trial, context)

    if PermissionGate.allowed?(permission_decision) do
      report = Sandbox.doctor()

      {:ok,
       %{
         message: message(report),
         status: report.status,
         permission_decision: permission_decision,
         doctor: DoctorReport.to_map(report),
         actions: [action(:completed, permission_decision, %{doctor_status: report.status})]
       }}
    else
      {:ok, denied(permission_decision)}
    end
  end

  defp message(report) do
    "Sandbox doctor status: #{report.status}; backend: #{inspect(report.resolved_backend)}"
  end

  defp denied(permission_decision) do
    %{
      message: "Sandbox doctor is denied by Security Central.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      doctor: %{},
      actions: [action(:denied, permission_decision, %{})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "sandbox_doctor",
      status: status,
      permission: :sandbox_trial,
      permission_decision: permission_decision,
      sandbox_metadata: metadata
    }
  end
end
