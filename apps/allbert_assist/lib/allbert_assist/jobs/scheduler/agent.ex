defmodule AllbertAssist.Jobs.Scheduler.Agent do
  @moduledoc """
  JidoBacked coordinator for scheduled-job polling.

  The scheduler's authoritative queue remains the `scheduled_jobs` and
  `scheduled_job_runs` SQLite tables. This agent owns lifecycle/tick commands
  and a small diagnostics projection. Tick scheduling uses
  `Jido.Agent.Directive.schedule/2`, which currently maps to
  `Process.send_after/3` inside Jido.AgentServer.
  """

  alias AllbertAssist.JidoBacked
  alias AllbertAssist.Jobs.Scheduler.Commands
  alias AllbertAssist.Jobs.Scheduler.Executor

  @run_once "allbert.jobs.scheduler.run_once"
  @cleanup_stale_runs "allbert.jobs.scheduler.cleanup_stale_runs"
  @tick "allbert.jobs.scheduler.tick"
  @schedule_next_tick "allbert.jobs.scheduler.schedule_next_tick"

  use JidoBacked,
    name: "allbert_jobs_scheduler",
    description: "Coordinates scheduled-job polling and tick lifecycle.",
    signal_routes: [
      {@run_once, Commands.RunOnce},
      {@cleanup_stale_runs, Commands.CleanupStaleRuns},
      {@tick, Commands.Tick},
      {@schedule_next_tick, Commands.ScheduleNextTick}
    ]

  @doc false
  @impl true
  def rebuild_state(opts) do
    state = Executor.build_state(opts)
    now = Executor.utc_now()

    with {:ok, _count} <- Executor.maybe_cleanup_on_start(state, now) do
      {:ok, state}
    end
  end

  @doc false
  @impl true
  def command_modules do
    [
      Commands.RunOnce,
      Commands.CleanupStaleRuns,
      Commands.Tick,
      Commands.ScheduleNextTick
    ]
  end

  @doc false
  @impl true
  def emit_debug_trace?(_state), do: JidoBacked.debug_trace_enabled?()

  @doc "Start the scheduler agent."
  @spec start_link() :: GenServer.on_start()
  def start_link, do: start_link([])

  @doc "Start the scheduler agent."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :name, AllbertAssist.Jobs.Scheduler)
    opts = Keyword.put_new(opts, :id, scheduler_id(Keyword.fetch!(opts, :name)))

    case JidoBacked.start_link(__MODULE__, opts) do
      {:ok, pid} = ok ->
        maybe_schedule_initial_tick(pid, opts)
        ok

      other ->
        other
    end
  end

  @doc false
  def run_once(server \\ AllbertAssist.Jobs.Scheduler, now \\ Executor.utc_now()) do
    JidoBacked.dispatch(server, @run_once, %{now: now},
      source: "/allbert/jobs/scheduler",
      timeout: :infinity
    )
  end

  @doc false
  def cleanup_stale_runs(server \\ AllbertAssist.Jobs.Scheduler, now \\ Executor.utc_now()) do
    JidoBacked.dispatch(server, @cleanup_stale_runs, %{now: now},
      source: "/allbert/jobs/scheduler",
      timeout: :infinity
    )
  end

  @doc false
  def schedule_next_tick(server, delay_ms) do
    JidoBacked.dispatch(server, @schedule_next_tick, %{delay_ms: delay_ms},
      source: "/allbert/jobs/scheduler",
      timeout: :infinity
    )
  end

  defp maybe_schedule_initial_tick(pid, opts) do
    enabled? = Keyword.get(opts, :enabled?, true)
    poll_on_start? = Keyword.get(opts, :poll_on_start?, true)
    delay_ms = Keyword.get(opts, :initial_delay_ms, 1_000)

    if enabled? and poll_on_start? do
      _result = schedule_next_tick(pid, delay_ms)
      :ok
    else
      :ok
    end
  end

  defp scheduler_id(name) when is_atom(name), do: Atom.to_string(name)
  defp scheduler_id(name), do: inspect(name)
end
