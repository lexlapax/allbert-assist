defmodule AllbertAssist.Actions.Artifacts.ListArtifacts do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :artifact_read,
    exposure: :internal,
    execution_mode: :artifact_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_artifacts",
    description: "List artifact metadata from Artifacts Central.",
    category: "artifacts",
    tags: ["artifacts", "read", "list"],
    schema: [
      mime: [type: :string, required: false],
      origin: [type: :string, required: false],
      retention: [type: :string, required: false],
      lifecycle: [type: :string, required: false],
      since: [type: :string, required: false],
      thread_id: [type: :string, required: false],
      user_id: [type: :string, required: false],
      role: [type: :string, required: false],
      limit: [type: :integer, required: false]
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
  @action_name "list_artifacts"

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, artifacts} <- Artifacts.list(list_opts(params, context)) do
      {:ok,
       %{
         message: "#{length(artifacts)} artifact(s) listed.",
         status: :completed,
         artifacts: artifacts,
         count: length(artifacts),
         permission_decision: permission_decision,
         actions: [
           Support.action(@action_name, :completed, @permission, permission_decision, %{
             lifecycle: "listed"
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

  defp list_opts(params, context) do
    [:mime, :origin, :retention, :lifecycle, :since, :thread_id, :user_id, :role, :limit]
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
       message: "Artifact list failed: #{inspect(Redactor.redact(reason))}",
       status: status,
       error: Redactor.redact(reason),
       permission_decision: permission_decision,
       actions: [Support.action(@action_name, status, @permission, permission_decision)]
     }}
  end
end
