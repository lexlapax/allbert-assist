defmodule AllbertAssist.Actions.Artifacts.ArtifactDoctor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :artifact_read,
    exposure: :internal,
    execution_mode: :artifact_doctor,
    skill_backed?: false,
    confirmation: :not_required,
    name: "artifact_doctor",
    description: "Report Artifacts Central policy and store health.",
    category: "artifacts",
    tags: ["artifacts", "doctor", "read"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Artifacts.Support
  alias AllbertAssist.Artifacts.Config
  alias AllbertAssist.Artifacts.GC
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate

  @permission :artifact_read
  @action_name "artifact_doctor"

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, gc} <- GC.sweep(delete_orphans?: false) do
      doctor = Config.doctor() |> Map.put(:gc_last_check, Map.drop(gc, [:removed]))

      {:ok,
       %{
         message: "Artifacts Central doctor completed.",
         status: :completed,
         doctor: Redactor.redact(doctor),
         permission_decision: permission_decision,
         actions: [
           Support.action(@action_name, :completed, @permission, permission_decision, %{
             lifecycle: "doctor"
           })
         ]
       }}
    else
      {:allowed, false} -> stopped(permission_decision, :permission_denied)
      {:error, reason} -> stopped(permission_decision, reason)
    end
  end

  defp stopped(permission_decision, reason) do
    status =
      if permission_decision.decision == :allowed,
        do: :error,
        else: PermissionGate.response_status(permission_decision)

    {:ok,
     %{
       message: "Artifact doctor failed: #{inspect(Redactor.redact(reason))}",
       status: status,
       error: Redactor.redact(reason),
       permission_decision: permission_decision,
       actions: [Support.action(@action_name, status, @permission, permission_decision)]
     }}
  end
end
