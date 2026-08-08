defmodule AllbertAssist.Actions.Jobs.ResumeJob do
  @moduledoc "Resume one of the local operator's own scheduled jobs (v0.61 M10.4)."

  use AllbertAssist.Action,
    registry_order: 198,
    permission: :job_write,
    exposure: :internal,
    execution_mode: :job_control,
    skill_backed?: false,
    confirmation: :not_required,
    name: "resume_job",
    description: "Resume a scheduled job owned by the local user.",
    category: "jobs",
    tags: ["jobs", "write"],
    schema: [
      id: [type: :string, required: false],
      job_id: [type: :string, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: :legacy_standard_response

  alias AllbertAssist.Actions.Jobs.Control
  alias AllbertAssist.Jobs

  @impl true
  def run(params, context) do
    Control.run("resume_job", params, context, fn job ->
      case Jobs.resume_job(job) do
        {:ok, resumed} -> {:ok, "Resumed #{resumed.name}"}
        {:error, reason} -> {:error, reason}
      end
    end)
  end
end
