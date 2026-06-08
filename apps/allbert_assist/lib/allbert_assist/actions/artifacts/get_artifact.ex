defmodule AllbertAssist.Actions.Artifacts.GetArtifact do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :artifact_read,
    exposure: :internal,
    execution_mode: :artifact_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "get_artifact",
    description: "Read one artifact from Artifacts Central.",
    category: "artifacts",
    tags: ["artifacts", "read", "cas"],
    schema: [
      sha256: [type: :string, required: false],
      artifact_uri: [type: :string, required: false],
      include_bytes: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Artifacts.Support
  alias AllbertAssist.Artifacts
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate

  @permission :artifact_read
  @action_name "get_artifact"

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, artifact_ref} <- artifact_ref(params),
         {:ok, artifact} <-
           Artifacts.get(artifact_ref,
             include_bytes?: Support.value(params, :include_bytes, false)
           ) do
      {:ok,
       %{
         message: "Artifact #{artifact.artifact_uri} read.",
         status: :completed,
         artifact: artifact,
         permission_decision: permission_decision,
         actions: [
           Support.action(
             @action_name,
             :completed,
             @permission,
             permission_decision,
             artifact.metadata
           )
         ]
       }}
    else
      {:allowed, false} -> stopped(permission_decision, :permission_denied)
      {:error, reason} -> stopped(permission_decision, reason)
    end
  end

  def run(_params, context),
    do: stopped(PermissionGate.authorize(@permission, context), :invalid_params)

  defp artifact_ref(params) do
    case Support.artifact_ref(params) do
      ref when is_binary(ref) and ref != "" -> {:ok, ref}
      _ref -> {:error, :missing_artifact_ref}
    end
  end

  defp stopped(permission_decision, reason) do
    status =
      if permission_decision.decision == :allowed,
        do: :error,
        else: PermissionGate.response_status(permission_decision)

    {:ok,
     %{
       message: "Artifact read failed: #{inspect(Redactor.redact(reason))}",
       status: status,
       error: Redactor.redact(reason),
       permission_decision: permission_decision,
       actions: [Support.action(@action_name, status, @permission, permission_decision)]
     }}
  end
end
