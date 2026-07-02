defmodule AllbertAssist.Actions.Jobs.RunJob do
  @moduledoc """
  Trigger a manual run of one of the local operator's own scheduled jobs (v0.61
  M10.4). The wrapper permission (`:job_write`) authorizes triggering the run; the
  run's own target executes through the normal boundary and any effectful sub-action
  still hits its own confirmation gate (including the job's blocked-confirmation path).
  """

  use AllbertAssist.Action,
    permission: :job_write,
    exposure: :internal,
    execution_mode: :job_control,
    skill_backed?: false,
    confirmation: :not_required,
    name: "run_job",
    description: "Create and execute a manual run for a scheduled job owned by the local user.",
    category: "jobs",
    tags: ["jobs", "write"],
    schema: [
      id: [type: :string, required: false],
      job_id: [type: :string, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Control
  alias AllbertAssist.Jobs.Runner

  @impl true
  def run(params, context) do
    Control.run("run_job", params, context, fn job ->
      case Runner.run_now(job) do
        {:ok, %{run: run}} -> {:ok, "Run #{run.id} #{run.status}"}
        {:error, reason} -> {:error, reason}
      end
    end)
  end
end
