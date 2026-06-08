defmodule AllbertAssist.Actions.Artifacts.PutArtifact do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :artifact_write,
    exposure: :internal,
    execution_mode: :artifact_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "put_artifact",
    description: "Write one retained artifact to Artifacts Central.",
    category: "artifacts",
    tags: ["artifacts", "write", "cas"],
    schema: [
      bytes: [type: :string, required: false],
      content_base64: [type: :string, required: false],
      metadata: [type: :map, required: false]
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

  @permission :artifact_write
  @action_name "put_artifact"

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    cond do
      permission_decision.decision == :denied ->
        stopped(permission_decision, :permission_denied)

      PermissionGate.allowed?(permission_decision) or Support.approved_resume?(context) ->
        put(params, context, permission_decision)

      permission_decision.decision == :needs_confirmation ->
        confirmation_not_supported(permission_decision)

      true ->
        stopped(permission_decision, :permission_denied)
    end
  end

  def run(_params, context),
    do: stopped(PermissionGate.authorize(@permission, context), :invalid_params)

  defp put(params, context, permission_decision) do
    with {:ok, bytes} <- bytes(params),
         {:ok, artifact} <- Artifacts.put_retained(bytes, metadata(params, context)) do
      {:ok,
       %{
         message: "Artifact stored as #{artifact.artifact_uri}.",
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
      {:error, reason} -> stopped(permission_decision, reason)
    end
  end

  defp bytes(params) do
    cond do
      is_binary(Support.value(params, :bytes)) ->
        {:ok, Support.value(params, :bytes)}

      is_binary(Support.value(params, :content_base64)) ->
        Base.decode64(Support.value(params, :content_base64))

      true ->
        {:error, :missing_artifact_bytes}
    end
  end

  defp metadata(params, context) do
    params
    |> Support.value(:metadata, %{})
    |> normalize_metadata()
    |> Map.put_new(:origin, Support.context_value(context, :channel, :action) |> to_string())
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp confirmation_not_supported(permission_decision) do
    {:ok,
     %{
       message: "Artifact write needs confirmation; bytes were not stored.",
       status: :needs_confirmation,
       error: :artifact_write_confirmation_requires_retry,
       permission_decision: permission_decision,
       actions: [
         Support.action(@action_name, :needs_confirmation, @permission, permission_decision, %{
           redaction_status: "bytes_not_persisted"
         })
       ]
     }}
  end

  defp stopped(permission_decision, reason) do
    status = failed_status(permission_decision, reason)

    {:ok,
     %{
       message: "Artifact write failed: #{inspect(Redactor.redact(reason))}",
       status: status,
       error: Redactor.redact(reason),
       permission_decision: permission_decision,
       actions: [Support.action(@action_name, status, @permission, permission_decision)]
     }}
  end

  defp failed_status(_permission_decision, reason)
       when reason in [:permission_denied, :artifacts_disabled, :artifact_retention_disabled],
       do: :denied

  defp failed_status(permission_decision, _reason)
       when permission_decision.decision in [:denied, :needs_confirmation],
       do: PermissionGate.response_status(permission_decision)

  defp failed_status(_permission_decision, _reason), do: :error
end
