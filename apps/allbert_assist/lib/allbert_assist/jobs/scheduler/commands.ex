defmodule AllbertAssist.Jobs.Scheduler.Commands do
  @moduledoc false

  alias AllbertAssist.Jobs.Scheduler.Executor
  alias Jido.Agent.Directive
  alias Jido.Signal

  @tick "allbert.jobs.scheduler.tick"

  @doc false
  def finish(command, result, state, opts \\ []) do
    now = Keyword.get(opts, :now, Executor.utc_now())

    case result do
      {:ok, value} ->
        {:ok,
         state
         |> Map.merge(%{
           last_command: command,
           last_result: {:ok, value},
           last_error: nil
         })
         |> maybe_put(:last_summary, summary_value(command, value))
         |> maybe_put(:last_tick_at, tick_at(command, now))}

      {:error, reason} ->
        {:ok,
         %{
           last_command: command,
           last_result: {:error, reason},
           last_error: inspect(reason)
         }}
    end
  end

  @doc false
  def schedule_directive(delay_ms) do
    signal = Signal.new!(@tick, %{}, source: "/allbert/jobs/scheduler")
    Directive.schedule(delay_ms, signal)
  end

  defp summary_value(command, value) when command in [:run_once, :tick], do: value
  defp summary_value(:cleanup_stale_runs, value), do: %{stale_runs_failed: value}
  defp summary_value(_command, _value), do: nil

  defp tick_at(command, now) when command in [:run_once, :tick] do
    now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp tick_at(_command, _now), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule AllbertAssist.Jobs.Scheduler.Commands.RunOnce do
  @moduledoc false

  use Jido.Action,
    name: "allbert_jobs_scheduler_run_once",
    description: "Private scheduled-job run-once command."

  alias AllbertAssist.Jobs.Scheduler.Commands
  alias AllbertAssist.Jobs.Scheduler.Executor

  @impl true
  def run(%{now: now}, context) do
    state = Map.fetch!(context, :state)
    Commands.finish(:run_once, Executor.poll_once(state, now), state, now: now)
  end
end

defmodule AllbertAssist.Jobs.Scheduler.Commands.CleanupStaleRuns do
  @moduledoc false

  use Jido.Action,
    name: "allbert_jobs_scheduler_cleanup_stale_runs",
    description: "Private scheduled-job stale-run cleanup command."

  alias AllbertAssist.Jobs.Scheduler.Commands
  alias AllbertAssist.Jobs.Scheduler.Executor

  @impl true
  def run(%{now: now}, context) do
    state = Map.fetch!(context, :state)
    Commands.finish(:cleanup_stale_runs, Executor.cleanup_stale_runs_for_state(state, now), state)
  end
end

defmodule AllbertAssist.Jobs.Scheduler.Commands.Tick do
  @moduledoc false

  use Jido.Action,
    name: "allbert_jobs_scheduler_tick",
    description: "Private scheduled-job tick command."

  alias AllbertAssist.Jobs.Scheduler.Commands
  alias AllbertAssist.Jobs.Scheduler.Executor

  @impl true
  def run(_params, context) do
    state = Map.fetch!(context, :state)
    now = Executor.utc_now()

    with {:ok, patch} <- Commands.finish(:tick, Executor.poll_once(state, now), state, now: now) do
      directives =
        if state.enabled? do
          [Commands.schedule_directive(state.interval_ms)]
        else
          []
        end

      {:ok, patch, directives}
    end
  end
end

defmodule AllbertAssist.Jobs.Scheduler.Commands.ScheduleNextTick do
  @moduledoc false

  use Jido.Action,
    name: "allbert_jobs_scheduler_schedule_next_tick",
    description: "Private scheduled-job tick scheduling command."

  alias AllbertAssist.Jobs.Scheduler.Commands

  @impl true
  def run(%{delay_ms: delay_ms}, context) do
    state = Map.fetch!(context, :state)

    if state.enabled? do
      {:ok,
       %{
         last_command: :schedule_next_tick,
         last_result: {:ok, :scheduled},
         last_error: nil
       }, [Commands.schedule_directive(delay_ms)]}
    else
      {:ok,
       %{
         last_command: :schedule_next_tick,
         last_result: {:ok, :disabled},
         last_error: nil
       }}
    end
  end
end
