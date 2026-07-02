defmodule AllbertAssistWeb.JobsLive do
  @moduledoc """
  Thin scheduled job inspection surface.

  Identity is a server-derived `"local"` id (`@user_id`), never the URL. Reads and the
  pause/resume/run effects route through the registered `list_jobs` / `pause_job` /
  `resume_job` / `run_job` Jido actions via `Runner.run/3` with a server-built context
  (v0.61 M10.4). Those actions resolve identity with the context-supplied user id ahead
  of any params value and load the job through the ownership-scoped `Jobs.get_job/2`, so
  a crafted `phx-value-id` for another user's job cannot be read, paused, resumed, or
  executed, and every effect passes the `:job_write` PermissionGate — restoring the
  ADR-0073 read-through-action boundary for this surface.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Surfaces.ContextBuilder
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
  def handle_event("pause", %{"id" => id}, socket),
    do: {:noreply, run_job_control(socket, "pause_job", id)}

  def handle_event("resume", %{"id" => id}, socket),
    do: {:noreply, run_job_control(socket, "resume_job", id)}

  def handle_event("run", %{"id" => id}, socket),
    do: {:noreply, run_job_control(socket, "run_job", id)}

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

  # Effectful job controls route through the registered pause_job/resume_job/run_job
  # actions (`:job_write` gate, ownership-scoped fetch under the server-derived
  # identity), then refresh the list. The action's message carries the blocked-by-
  # confirmation guidance; any non-completed status surfaces as the notice.
  defp run_job_control(socket, action_name, id) do
    params = %{id: id, user_id: socket.assigns.user_id}

    case Runner.run(action_name, params, job_context()) do
      {:ok, %{status: :completed, message: message}} ->
        socket |> assign(:notice, message) |> load_jobs()

      {:ok, response} ->
        assign(socket, :notice, Map.get(response, :message, inspect(response)))
    end
  end

  defp load_jobs(socket) do
    {jobs, runs_by_job} =
      case Runner.run("list_jobs", %{user_id: socket.assigns.user_id}, job_context()) do
        {:ok, %{status: :completed, jobs: jobs, runs_by_job: runs_by_job}} ->
          {jobs, runs_by_job}

        _other ->
          {[], %{}}
      end

    socket
    |> assign(:jobs, jobs)
    |> assign(:runs_by_job, runs_by_job)
    |> assign(:jobs_surface, jobs_surface(jobs, runs_by_job))
  end

  # Server-built context pins the identity to @user_id ahead of any params value, so
  # the registered actions scope reads/effects to the local operator (ADR 0073).
  defp job_context do
    ContextBuilder.live_view_context(%{user_id: @user_id}, surface: "AllbertAssistWeb.JobsLive")
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
