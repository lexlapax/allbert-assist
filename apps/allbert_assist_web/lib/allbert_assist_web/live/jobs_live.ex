defmodule AllbertAssistWeb.JobsLive do
  @moduledoc """
  Thin scheduled job inspection surface.

  v0.61 M10.3 pins identity to a server-derived `"local"` id (`@user_id`) rather than
  the URL-controllable `?user=` param the surface previously read verbatim — closing
  the objectives-index IDOR's sibling here. The list is scoped to that identity, and
  the pause/resume/run effects load the job through the ownership-scoped
  `Jobs.get_job/2` so a crafted `phx-value-id` for another user's job cannot be read,
  paused, resumed, or executed.

  The reads/effects still resolve through the `Jobs` context directly rather than
  registered Jido actions: unlike Objectives, Jobs has no registered
  list/pause/resume/run actions, and adding them is a data-layer change out of the
  v0.61 presentation scope. Migrating this surface onto a registered-action boundary
  (ADR 0073) is deferred to the version that introduces those job actions; the
  server-derived, ownership-scoped identity closes the disclosure and cross-user
  effect in the meantime.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Runner
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssistWeb.Workspace.Components.Patterns
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer

  @user_id "local"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:user_id, @user_id)
      |> assign(:page_title, "Scheduled Jobs")
      |> assign(:notice, nil)
      |> load_jobs()

    {:ok, socket}
  end

  @impl true
  def handle_event("pause", %{"id" => id}, socket) do
    result =
      with {:ok, job} <- Jobs.get_job(socket.assigns.user_id, id),
           {:ok, paused} <- Jobs.pause_job(job) do
        {:ok, "Paused #{paused.name}"}
      end

    {:noreply, handle_result(socket, result)}
  end

  def handle_event("resume", %{"id" => id}, socket) do
    result =
      with {:ok, job} <- Jobs.get_job(socket.assigns.user_id, id),
           {:ok, resumed} <- Jobs.resume_job(job) do
        {:ok, "Resumed #{resumed.name}"}
      end

    {:noreply, handle_result(socket, result)}
  end

  def handle_event("run", %{"id" => id}, socket) do
    result =
      with {:ok, job} <- Jobs.get_job(socket.assigns.user_id, id),
           {:ok, %{run: run}} <- Runner.run_now(job) do
        {:ok, "Run #{run.id} #{run.status}"}
      end

    {:noreply, handle_result(socket, result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} content_width="full">
      <Layouts.operator_shell
        active="jobs"
        title="Scheduled Jobs"
        subtitle="Recurring runtime work, runs, and blockers"
        labelledby="jobs-page-title"
      >
        <Patterns.status_callout id="jobs-notice" message={@notice} />

        <Patterns.elevated_card id="jobs-list" aria-labelledby="jobs-page-title">
          <.live_component
            module={WorkspaceRenderer}
            id="jobs-catalog-renderer"
            surface={@jobs_surface}
            renderer_context={%{user_id: @user_id, page: :jobs}}
            workspace_state={%{}}
          />
        </Patterns.elevated_card>
      </Layouts.operator_shell>
    </Layouts.app>
    """
  end

  defp jobs_surface(jobs, runs_by_job) do
    %Surface{
      id: "jobs-page",
      app_id: :allbert,
      label: "Scheduled Jobs",
      kind: :workspace,
      status: :available,
      nodes: job_nodes(jobs, runs_by_job)
    }
  end

  defp job_nodes([], _runs_by_job) do
    [
      %Node{
        id: "jobs-empty",
        component: :empty_state,
        props: %{
          title: "No scheduled jobs.",
          body: "Scheduled runtime work appears here after it is created."
        }
      }
    ]
  end

  defp job_nodes(jobs, runs_by_job) do
    Enum.map(jobs, fn job ->
      job_card_node(job, Map.get(runs_by_job, job.id, []))
    end)
  end

  defp job_card_node(%Job{} = job, runs) do
    %Node{
      id: "job-#{job.id}",
      component: :job_card,
      props: %{
        dom_id: "job-#{job.id}",
        title: job.name,
        body: job_body(job, runs),
        status: job.status,
        external_id: job.id
      },
      children: job_action_nodes(job)
    }
  end

  defp job_action_nodes(%Job{} = job) do
    [
      %Node{
        id: "job-#{job.id}-run",
        component: :button,
        props: %{
          dom_id: "run-#{job.id}",
          title: "Run",
          phx_click: "run",
          value_id: job.id,
          variant: "primary"
        }
      },
      maybe_pause_node(job),
      maybe_resume_node(job)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_pause_node(%Job{status: "active"} = job) do
    %Node{
      id: "job-#{job.id}-pause",
      component: :button,
      props: %{
        dom_id: "pause-#{job.id}",
        title: "Pause",
        phx_click: "pause",
        value_id: job.id,
        variant: "secondary"
      }
    }
  end

  defp maybe_pause_node(_job), do: nil

  defp maybe_resume_node(%Job{status: status} = job) when status in ["paused", "blocked"] do
    %Node{
      id: "job-#{job.id}-resume",
      component: :button,
      props: %{
        dom_id: "resume-#{job.id}",
        title: "Resume",
        phx_click: "resume",
        value_id: job.id,
        variant: "secondary"
      }
    }
  end

  defp maybe_resume_node(_job), do: nil

  defp job_body(%Job{} = job, runs) do
    [
      "status=#{job.status}",
      "target=#{job.target_type}",
      "schedule=#{schedule_text(job.schedule)} #{job.timezone}",
      "thread=#{thread_text(job)}",
      "next=#{datetime_text(job.next_due_at)}",
      "last=#{datetime_text(job.last_run_at)}",
      blocked_confirmation_text(job),
      recent_runs_text(runs)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp blocked_confirmation_text(%Job{blocked_confirmation_id: id})
       when is_binary(id) and id != "" do
    "confirmation #{id}"
  end

  defp blocked_confirmation_text(_job), do: nil

  defp recent_runs_text([]), do: "Recent Runs: No runs."

  defp recent_runs_text(runs) do
    runs
    |> Enum.map(&run_text/1)
    |> Enum.join(" | ")
    |> then(&"Recent Runs: #{&1}")
  end

  defp run_text(%Run{} = run) do
    [
      run.id,
      "status=#{run.status}",
      "trigger=#{run.trigger}",
      "duration=#{run.duration_ms || "none"}",
      "confirmation=#{run.confirmation_id || "none"}"
      | handoff_lines(run)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
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
    |> assign(:jobs_surface, jobs_surface(jobs, runs_by_job))
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

  defp blank?(nil), do: true

  defp blank?(value) do
    value
    |> to_string()
    |> String.trim()
    |> Kernel.==("")
  end
end
