defmodule AllbertAssist.Actions.Artifacts.DeleteArtifact do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :artifact_delete,
    exposure: :internal,
    execution_mode: :artifact_delete,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "delete_artifact",
    description: "Delete one artifact from Artifacts Central after confirmation.",
    category: "artifacts",
    tags: ["artifacts", "delete", "confirmation"],
    schema: [
      sha256: [type: :string, required: false],
      artifact_uri: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Artifacts.Support
  alias AllbertAssist.Artifacts
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate

  @permission :artifact_delete
  @action_name "delete_artifact"

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:denied, false} <- {:denied, permission_decision.decision == :denied},
         {:ok, artifact_ref} <- artifact_ref(params) do
      if Support.approved_resume?(context) do
        delete_now(artifact_ref, permission_decision, :approval)
      else
        create_confirmation(artifact_ref, context, permission_decision)
      end
    else
      {:denied, true} -> stopped(permission_decision, :permission_denied, :denied)
      {:error, reason} -> stopped(permission_decision, reason, :error)
    end
  end

  def run(_params, context),
    do: stopped(PermissionGate.authorize(@permission, context), :invalid_params, :error)

  defp delete_now(artifact_ref, permission_decision, execution) do
    case Artifacts.delete(artifact_ref) do
      {:ok, deleted} ->
        {:ok,
         %{
           message: "Artifact #{deleted.artifact_uri} deleted.",
           status: :completed,
           artifact: Map.drop(deleted, [:metadata]),
           permission_decision: permission_decision,
           actions: [
             Support.action(
               @action_name,
               :completed,
               @permission,
               permission_decision,
               Map.put(deleted.metadata, :lifecycle, "deleted")
             )
             |> Map.put(:execution, execution)
           ]
         }}

      {:error, reason} ->
        stopped(permission_decision, reason, :error)
    end
  end

  defp create_confirmation(artifact_ref, context, permission_decision) do
    with {:ok, artifact} <- Artifacts.get(artifact_ref),
         {:ok, confirmation} <-
           Confirmations.create(%{
             origin: Origin.from_context(context, @action_name),
             target_action: %{name: @action_name, module: inspect(__MODULE__)},
             target_permission: @permission,
             target_execution_mode: :artifact_delete,
             security_decision: permission_decision,
             source_signal_id: Support.context_value(context, :runner_requested_signal_id),
             params_summary: %{
               sha256: artifact.sha256,
               artifact_uri: artifact.artifact_uri,
               metadata: Redactor.redact_artifact_metadata(artifact.metadata)
             },
             resume_params_ref: %{
               sha256: artifact.sha256
             }
           }) do
      confirmation_id = confirmation["id"] || confirmation[:id]

      {:ok,
       %{
         message: "Artifact deletion needs confirmation.",
         status: :needs_confirmation,
         artifact: Map.take(artifact, [:sha256, :artifact_uri, :metadata]),
         confirmation: confirmation,
         confirmation_id: confirmation_id,
         permission_decision: permission_decision,
         actions: [
           Support.action(
             @action_name,
             :needs_confirmation,
             @permission,
             permission_decision,
             artifact.metadata
           )
           |> Map.put(:execution, :pending_confirmation)
           |> Map.put(:confirmation_id, confirmation_id)
         ]
       }}
    else
      {:error, reason} -> stopped(permission_decision, reason, :error)
    end
  end

  defp artifact_ref(params) do
    case Support.artifact_ref(params) do
      ref when is_binary(ref) and ref != "" -> {:ok, ref}
      _ref -> {:error, :missing_artifact_ref}
    end
  end

  defp stopped(permission_decision, reason, status) do
    {:ok,
     %{
       message: "Artifact delete failed: #{inspect(Redactor.redact(reason))}",
       status: status,
       error: Redactor.redact(reason),
       permission_decision: permission_decision,
       actions: [Support.action(@action_name, status, @permission, permission_decision)]
     }}
  end
end
