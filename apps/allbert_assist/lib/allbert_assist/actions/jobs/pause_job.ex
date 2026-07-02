defmodule AllbertAssist.Actions.Jobs.PauseJob do
  @moduledoc "Pause one of the local operator's own scheduled jobs (v0.61 M10.4)."

  use AllbertAssist.Action,
    permission: :job_write,
    exposure: :internal,
    execution_mode: :job_control,
    skill_backed?: false,
    confirmation: :not_required,
    name: "pause_job",
    description: "Pause a scheduled job owned by the local user.",
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
  alias AllbertAssist.Jobs

  @impl true
  def run(params, context) do
    Control.run("pause_job", params, context, fn job ->
      case Jobs.pause_job(job) do
        {:ok, paused} -> {:ok, "Paused #{paused.name}"}
        {:error, reason} -> {:error, reason}
      end
    end)
  end
end
