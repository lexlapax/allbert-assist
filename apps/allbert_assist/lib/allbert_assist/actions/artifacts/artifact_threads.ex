defmodule AllbertAssist.Actions.Artifacts.ArtifactThreads do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :artifact_read,
    exposure: :internal,
    execution_mode: :artifact_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "artifact_threads",
    description: "List thread/message provenance links for one artifact.",
    category: "artifacts",
    tags: ["artifacts", "read", "provenance", "threads"],
    schema: [
      sha256: [type: :string, required: false],
      artifact_uri: [type: :string, required: false],
      user_id: [type: :string, required: false],
      role: [type: :string, required: false]
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
  @action_name "artifact_threads"

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, artifact_ref} <- artifact_ref(params),
         {:ok, links} <- Artifacts.artifact_threads(artifact_ref, thread_opts(params, context)) do
      {:ok,
       %{
         message: "#{length(links)} artifact thread link(s) listed.",
         status: :completed,
         links: links,
         count: length(links),
         permission_decision: permission_decision,
         actions: [
           Support.action(@action_name, :completed, @permission, permission_decision, %{
             lifecycle: "thread_links_listed"
           })
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

  defp thread_opts(params, context) do
    [:user_id, :role]
    |> Enum.flat_map(fn key ->
      case Support.value(params, key) do
        nil -> []
        value -> [{key, value}]
      end
    end)
    |> Keyword.put_new(:user_id, Support.context_value(context, :user_id))
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp stopped(permission_decision, reason) do
    status =
      if permission_decision.decision == :allowed,
        do: :error,
        else: PermissionGate.response_status(permission_decision)

    {:ok,
     %{
       message: "Artifact thread lookup failed: #{inspect(Redactor.redact(reason))}",
       status: status,
       error: Redactor.redact(reason),
       permission_decision: permission_decision,
       actions: [Support.action(@action_name, status, @permission, permission_decision)]
     }}
  end
end
