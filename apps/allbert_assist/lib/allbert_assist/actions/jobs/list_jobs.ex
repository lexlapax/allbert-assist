defmodule AllbertAssist.Actions.Jobs.ListJobs do
  @moduledoc """
  List scheduled jobs (with recent runs) for one local user through the registered
  read-only boundary. Replaces JobsLive's direct `Jobs.list_jobs/2` read (v0.61 M10.4).
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_jobs",
    description: "List scheduled jobs and their recent runs for a local user.",
    category: "jobs",
    tags: ["jobs", "read_only"],
    schema: [
      user_id: [type: :string, required: false],
      runs_limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      jobs: [type: {:list, :map}, required: true],
      runs_by_job: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Jobs
  alias AllbertAssist.Security.PermissionGate

  @default_runs_limit 3

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Identity.user_id(params, context) do
      jobs = Jobs.list_jobs(user_id)
      runs_limit = Identity.field(params, :runs_limit) || @default_runs_limit
      runs_by_job = Map.new(jobs, fn job -> {job.id, Jobs.list_runs(job, limit: runs_limit)} end)

      {:ok,
       %{
         message: "Found #{length(jobs)} job(s).",
         status: :completed,
         permission_decision: permission_decision,
         jobs: jobs,
         runs_by_job: runs_by_job,
         actions: [
           %{
             name: "list_jobs",
             status: :completed,
             permission: :read_only,
             permission_decision: permission_decision,
             user_id: user_id,
             job_count: length(jobs)
           }
         ]
       }}
    else
      {:allowed, false} ->
        {:ok,
         %{
           message: permission_decision.reason,
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           jobs: [],
           runs_by_job: %{},
           actions: [
             %{
               name: "list_jobs",
               status: :denied,
               permission: :read_only,
               permission_decision: permission_decision
             }
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Unable to list jobs: #{inspect(reason)}",
           status: :error,
           error: reason,
           permission_decision: permission_decision,
           jobs: [],
           runs_by_job: %{},
           actions: [
             %{
               name: "list_jobs",
               status: :error,
               permission: :read_only,
               permission_decision: permission_decision,
               error: reason
             }
           ]
         }}
    end
  end
end
