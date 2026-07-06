defmodule AllbertAssist.Actions.Jobs.CreateJob do
  @moduledoc """
  Create a scheduled job owned by the local operator (v0.62 M8.15). The job is
  always written under the server-derived identity (context `user_id` ahead of any
  params-supplied value), so the CLI create path cannot scope a new job to another
  user via the request body — the same ownership boundary the pause/resume/run
  controls rely on.
  """

  use AllbertAssist.Action,
    permission: :job_write,
    exposure: :internal,
    execution_mode: :job_control,
    skill_backed?: false,
    confirmation: :not_required,
    name: "create_job",
    description: "Create a scheduled job owned by the local user.",
    category: "jobs",
    tags: ["jobs", "write"],
    schema: [
      attrs: [type: :map, required: true],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      job: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Jobs
  alias AllbertAssist.Security.PermissionGate

  @permission :job_write

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Identity.user_id(params, context),
         {:ok, attrs} <- job_attrs(params, user_id),
         {:ok, job} <- Jobs.create_job(attrs) do
      {:ok, completed(permission_decision, job, user_id)}
    else
      {:allowed, false} -> {:ok, denied(permission_decision)}
      {:error, reason} -> {:ok, errored(permission_decision, reason)}
    end
  end

  defp job_attrs(params, user_id) do
    case Identity.field(params, :attrs) do
      attrs when is_map(attrs) ->
        {:ok,
         attrs
         |> Map.put(:user_id, user_id)
         |> Map.put(:operator_id, user_id)}

      _other ->
        {:error, :missing_job_attrs}
    end
  end

  defp completed(permission_decision, job, user_id) do
    %{
      message: "Created #{job.id}",
      status: :completed,
      permission_decision: permission_decision,
      job: job,
      actions: [
        %{
          name: "create_job",
          status: :completed,
          permission: @permission,
          permission_decision: permission_decision,
          user_id: user_id,
          job_id: job.id
        }
      ]
    }
  end

  defp denied(permission_decision) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [
        %{
          name: "create_job",
          status: :denied,
          permission: @permission,
          permission_decision: permission_decision
        }
      ]
    }
  end

  defp errored(permission_decision, reason) do
    %{
      message: "Job creation failed: #{inspect(reason)}",
      status: :error,
      error: reason,
      permission_decision: permission_decision,
      actions: [
        %{
          name: "create_job",
          status: :error,
          permission: @permission,
          permission_decision: permission_decision,
          error: reason
        }
      ]
    }
  end
end
