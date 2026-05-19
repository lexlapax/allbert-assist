defmodule AllbertAssistWeb.JobsLive do
  @moduledoc """
  Thin scheduled job inspection surface.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Runner

  @impl true
  def mount(params, _session, socket) do
    user_id = params |> Map.get("user", "local") |> blank_to_default("local")

    socket =
      socket
      |> assign(:user_id, user_id)
      |> assign(:notice, nil)
      |> load_jobs()

    {:ok, socket}
  end

  @impl true
  def handle_event("pause", %{"id" => id}, socket) do
    result =
      with {:ok, job} <- Jobs.get_job(id),
           {:ok, paused} <- Jobs.pause_job(job) do
        {:ok, "Paused #{paused.name}"}
      end

    {:noreply, handle_result(socket, result)}
  end

  def handle_event("resume", %{"id" => id}, socket) do
    result =
      with {:ok, job} <- Jobs.get_job(id),
           {:ok, resumed} <- Jobs.resume_job(job) do
        {:ok, "Resumed #{resumed.name}"}
      end

    {:noreply, handle_result(socket, result)}
  end

  def handle_event("run", %{"id" => id}, socket) do
    result =
      with {:ok, %{run: run}} <- Runner.run_now(id) do
        {:ok, "Run #{run.id} #{run.status}"}
      end

    {:noreply, handle_result(socket, result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-6xl px-6 py-8">
      <header class="mb-6 flex items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Scheduled Jobs</h1>
          <p class="text-sm text-zinc-600">User {@user_id}</p>
        </div>
        <a class="text-sm font-medium text-blue-700 hover:text-blue-900" href="/settings">Settings</a>
      </header>

      <p
        :if={@notice}
        id="jobs-notice"
        class="mb-4 rounded border border-zinc-200 bg-zinc-50 px-3 py-2 text-sm"
      >
        {@notice}
      </p>

      <section id="jobs-list" class="overflow-x-auto">
        <table class="w-full border-collapse text-left text-sm">
          <thead>
            <tr class="border-b border-zinc-200 text-xs uppercase text-zinc-500">
              <th class="py-2 pr-3">Job</th>
              <th class="py-2 pr-3">Status</th>
              <th class="py-2 pr-3">Schedule</th>
              <th class="py-2 pr-3">Thread</th>
              <th class="py-2 pr-3">Next</th>
              <th class="py-2 pr-3">Last</th>
              <th class="py-2 pr-3">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@jobs == []}>
              <td colspan="7" class="py-5 text-zinc-500">No scheduled jobs.</td>
            </tr>
            <tr :for={job <- @jobs} id={"job-#{job.id}"} class="border-b border-zinc-100 align-top">
              <td class="py-3 pr-3">
                <div class="font-medium text-zinc-900">{job.name}</div>
                <div class="font-mono text-xs text-zinc-500">{job.id}</div>
                <div class="text-xs text-zinc-500">{job.target_type}</div>
                <div :if={job.blocked_confirmation_id} class="mt-1 text-xs text-amber-700">
                  confirmation {job.blocked_confirmation_id}
                </div>
              </td>
              <td class="py-3 pr-3">{job.status}</td>
              <td class="py-3 pr-3">
                <div>{schedule_text(job.schedule)}</div>
                <div class="text-xs text-zinc-500">{job.timezone}</div>
              </td>
              <td class="py-3 pr-3">{thread_text(job)}</td>
              <td class="py-3 pr-3">{datetime_text(job.next_due_at)}</td>
              <td class="py-3 pr-3">{datetime_text(job.last_run_at)}</td>
              <td class="py-3 pr-3">
                <div class="flex flex-wrap gap-2">
                  <button
                    id={"run-#{job.id}"}
                    type="button"
                    phx-click="run"
                    phx-value-id={job.id}
                    class="rounded border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50"
                  >
                    Run
                  </button>
                  <button
                    :if={job.status == "active"}
                    id={"pause-#{job.id}"}
                    type="button"
                    phx-click="pause"
                    phx-value-id={job.id}
                    class="rounded border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50"
                  >
                    Pause
                  </button>
                  <button
                    :if={job.status in ["paused", "blocked"]}
                    id={"resume-#{job.id}"}
                    type="button"
                    phx-click="resume"
                    phx-value-id={job.id}
                    class="rounded border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50"
                  >
                    Resume
                  </button>
                </div>
              </td>
            </tr>
            <tr
              :for={job <- @jobs}
              id={"runs-#{job.id}"}
              class="border-b border-zinc-200 bg-zinc-50/50"
            >
              <td colspan="7" class="px-3 py-3">
                <div class="mb-2 text-xs font-semibold uppercase text-zinc-500">Recent Runs</div>
                <div :if={Map.get(@runs_by_job, job.id, []) == []} class="text-sm text-zinc-500">
                  No runs.
                </div>
                <div :for={run <- Map.get(@runs_by_job, job.id, [])} class="mb-2 text-sm">
                  <span class="font-mono text-xs text-zinc-500">{run.id}</span>
                  <span>status={run.status}</span>
                  <span>trigger={run.trigger}</span>
                  <span>duration={run.duration_ms || "none"}</span>
                  <span>confirmation={run.confirmation_id || "none"}</span>
                  <div :for={line <- handoff_lines(run)} class="text-xs text-amber-700">{line}</div>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </main>
    """
  end

  defp handle_result(socket, {:ok, notice}) do
    socket
    |> assign(:notice, notice)
    |> load_jobs()
  end

  defp handle_result(socket, {:error, reason}) do
    assign(socket, :notice, error_notice(reason))
  end

  defp error_notice({:blocked_by_confirmation, confirmation_id}) do
    "Job is blocked by pending confirmation #{confirmation_id}. Inspect it with mix allbert.confirmations show #{confirmation_id}."
  end

  defp error_notice(reason), do: "Error: #{inspect(reason)}"

  defp load_jobs(socket) do
    jobs = Jobs.list_jobs(socket.assigns.user_id)
    runs_by_job = Map.new(jobs, fn job -> {job.id, Jobs.list_runs(job, limit: 3)} end)

    socket
    |> assign(:jobs, jobs)
    |> assign(:runs_by_job, runs_by_job)
  end

  defp schedule_text(%{"kind" => "manual"}), do: "manual"
  defp schedule_text(%{"kind" => "daily", "at" => at}), do: "daily@#{at}"

  defp schedule_text(%{"kind" => "weekly", "weekday" => weekday, "at" => at}),
    do: "weekly:#{weekday}@#{at}"

  defp schedule_text(%{"kind" => "cron", "expression" => expression}), do: "cron:#{expression}"
  defp schedule_text(schedule), do: inspect(schedule)

  defp thread_text(%Job{thread_mode: "origin_thread", thread_id: thread_id}),
    do: "origin:#{thread_id}"

  defp thread_text(%Job{thread_mode: "new_thread_per_run"}), do: "new_per_run"
  defp thread_text(_job), do: "recent"

  defp handoff_lines(%Run{approval_handoff: handoff}) do
    if blank_handoff?(handoff) do
      []
    else
      handoff
      |> ApprovalHandoff.lines()
      |> Enum.reject(&blank_handoff_line?/1)
    end
  end

  defp blank_handoff?(nil), do: true
  defp blank_handoff?(handoff) when is_map(handoff), do: map_size(handoff) == 0
  defp blank_handoff?(_handoff), do: false

  defp blank_handoff_line?(line) do
    line
    |> to_string()
    |> String.trim()
    |> String.match?(~r/^Approval:\s*status=\s*target=$/)
  end

  defp datetime_text(nil), do: "none"
  defp datetime_text(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_text(value), do: to_string(value)

  defp blank_to_default(value, default) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> default
      value -> value
    end
  end
end
