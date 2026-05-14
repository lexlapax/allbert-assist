defmodule AllbertAssist.Actions.Jobs.TraceSummary do
  @moduledoc """
  Read-only trace and job-run summary for scheduled job templates.
  """

  use Jido.Action,
    name: "trace_summary",
    description: "Summarize recent trace files and scheduled job run counts.",
    category: "jobs",
    tags: ["jobs", "traces", "read_only"],
    schema: [
      limit: [type: :integer, required: false, doc: "Maximum recent failed runs to include."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      trace_summary: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  import Ecto.Query

  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Memory
  alias AllbertAssist.Repo
  alias AllbertAssist.Security.PermissionGate

  @default_limit 5

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    summary = summary(limit(params))

    {:ok,
     %{
       message: message(summary),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       trace_summary: summary,
       actions: [
         %{
           name: "trace_summary",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           trace_summary: summary
         }
       ]
     }}
  end

  defp summary(limit) do
    %{
      traces: %{
        count: trace_count()
      },
      job_runs: %{
        total: Repo.aggregate(Run, :count, :id),
        completed: run_count("completed"),
        needs_confirmation: run_count("needs_confirmation"),
        failed: run_count("failed"),
        running: run_count("running"),
        recent_failures: recent_failures(limit)
      }
    }
  end

  defp run_count(status) do
    Run
    |> where([run], run.status == ^status)
    |> Repo.aggregate(:count, :id)
  end

  defp recent_failures(limit) do
    Run
    |> where([run], run.status == "failed")
    |> order_by([run], desc: run.finished_at, desc: run.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn run ->
      %{
        run_id: run.id,
        job_id: run.job_id,
        finished_at: run.finished_at,
        error: run.error
      }
    end)
  end

  defp trace_count do
    Memory.ensure_root!()
    |> Path.join("traces/*.md")
    |> Path.wildcard()
    |> length()
  end

  defp message(summary) do
    """
    Trace summary:
    Trace files: #{summary.traces.count}
    Job runs: #{summary.job_runs.total} total, #{summary.job_runs.completed} completed, #{summary.job_runs.needs_confirmation} needs confirmation, #{summary.job_runs.failed} failed
    """
    |> String.trim()
  end

  defp limit(%{limit: limit}) when is_integer(limit) and limit > 0, do: min(limit, 25)
  defp limit(%{"limit" => limit}) when is_integer(limit) and limit > 0, do: min(limit, 25)
  defp limit(_params), do: @default_limit
end
