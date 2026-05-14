defmodule AllbertAssist.Jobs.Scheduler do
  @moduledoc """
  Supervised local scheduler for v0.13 scheduled jobs.

  The scheduler keeps no authoritative queue in memory. Each tick re-reads due
  jobs from SQLite and claims runs durably before executing them.
  """

  use GenServer

  require Logger

  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Runner
  alias AllbertAssist.Settings
  alias AllbertAssist.Signals
  alias Jido.Signal

  @default_interval_ms 60_000
  @default_initial_delay_ms 1_000
  @default_batch_size 5
  @default_stale_run_ms 5 * 60 * 1_000

  @job_signals %{
    due: "allbert.job.due",
    started: "allbert.job.started",
    completed: "allbert.job.completed",
    needs_confirmation: "allbert.job.needs_confirmation",
    failed: "allbert.job.failed",
    skipped: "allbert.job.skipped"
  }

  defstruct [
    :name,
    :interval_ms,
    :initial_delay_ms,
    :batch_size,
    :stale_run_ms,
    :enabled?,
    :poll_on_start?,
    :cleanup_on_start?
  ]

  @doc "Start the supervised scheduler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Run one scheduler polling cycle synchronously."
  @spec run_once(GenServer.server(), DateTime.t()) :: {:ok, map()}
  def run_once(server \\ __MODULE__, now \\ utc_now()) do
    GenServer.call(server, {:run_once, now}, :infinity)
  end

  @doc "Fail stale running rows synchronously."
  @spec cleanup_stale_runs(GenServer.server(), DateTime.t()) :: {:ok, non_neg_integer()}
  def cleanup_stale_runs(server \\ __MODULE__, now \\ utc_now()) do
    GenServer.call(server, {:cleanup_stale_runs, now}, :infinity)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.get(opts, :name, __MODULE__),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      initial_delay_ms: Keyword.get(opts, :initial_delay_ms, @default_initial_delay_ms),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      stale_run_ms: Keyword.get(opts, :stale_run_ms, @default_stale_run_ms),
      enabled?: Keyword.get(opts, :enabled?, true),
      poll_on_start?: Keyword.get(opts, :poll_on_start?, true),
      cleanup_on_start?: Keyword.get(opts, :cleanup_on_start?, true)
    }

    if state.cleanup_on_start? do
      cleanup_stale_runs_for_state(state, utc_now())
    end

    if state.enabled? and state.poll_on_start? do
      schedule_tick(state.initial_delay_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:run_once, now}, _from, state) do
    {:reply, poll_once(state, now), state}
  end

  def handle_call({:cleanup_stale_runs, now}, _from, state) do
    {:reply, cleanup_stale_runs_for_state(state, now), state}
  end

  @impl true
  def handle_info(:tick, state) do
    _summary = poll_once(state, utc_now())

    if state.enabled? do
      schedule_tick(state.interval_ms)
    end

    {:noreply, state}
  end

  defp poll_once(%__MODULE__{enabled?: false}, _now) do
    {:ok, base_summary("disabled")}
  end

  defp poll_once(%__MODULE__{} = state, now) do
    case Settings.get("jobs.schedule_policy") do
      {:ok, "operator_approved"} ->
        run_due_jobs(state, now)

      {:ok, "paused"} ->
        {:ok, base_summary("paused")}

      {:ok, other} ->
        Logger.warning("unknown jobs.schedule_policy=#{inspect(other)}; scheduler paused")
        {:ok, base_summary("paused")}

      {:error, reason} ->
        Logger.warning("could not read jobs.schedule_policy: #{inspect(reason)}")
        {:ok, base_summary("paused")}
    end
  end

  defp run_due_jobs(state, now) do
    now
    |> Jobs.due_jobs(state.batch_size)
    |> Enum.reduce(base_summary("operator_approved"), fn job, summary ->
      merge_summary(summary, run_due_job(job, now))
    end)
    |> then(&{:ok, &1})
  end

  defp run_due_job(%Job{} = job, now) do
    case Jobs.claim_due_job(job, now) do
      {:ok, %Run{} = run} ->
        emit_job_signal(:due, job, run)
        emit_job_signal(:started, job, run, %{started_at: utc_now()})
        execute_claimed_run(job, run)

      {:error, reason} ->
        emit_job_signal(:skipped, job, nil, %{reason: inspect(reason)})
        %{claimed: 0, completed: 0, needs_confirmation: 0, failed: 0, skipped: 1}
    end
  end

  defp execute_claimed_run(job, run) do
    case Runner.execute_run(job, run) do
      {:ok, %{job: updated_job, run: finished_run}} ->
        maybe_advance_next_due(updated_job, finished_run)
        emit_final_signal(updated_job, finished_run)
        summary_for_run(finished_run)

      {:error, reason} ->
        Logger.warning(
          "scheduled job execution failed job_id=#{job.id} reason=#{inspect(reason)}"
        )

        emit_job_signal(:failed, job, run, %{reason: inspect(reason)})
        %{claimed: 1, completed: 0, needs_confirmation: 0, failed: 1, skipped: 0}
    end
  end

  defp maybe_advance_next_due(%Job{status: "active"} = job, %Run{status: status})
       when status in ["completed", "failed", "skipped"] do
    case Jobs.advance_next_due(job) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not advance scheduled job next_due_at job_id=#{job.id}: #{inspect(reason)}"
        )
    end
  end

  defp maybe_advance_next_due(_job, _run), do: :ok

  defp emit_final_signal(job, %Run{status: "completed"} = run),
    do: emit_job_signal(:completed, job, run)

  defp emit_final_signal(job, %Run{status: "needs_confirmation"} = run),
    do: emit_job_signal(:needs_confirmation, job, run)

  defp emit_final_signal(job, %Run{status: "failed"} = run),
    do: emit_job_signal(:failed, job, run)

  defp emit_final_signal(job, %Run{status: "skipped"} = run),
    do: emit_job_signal(:skipped, job, run)

  defp emit_final_signal(_job, _run), do: :ok

  defp summary_for_run(%Run{status: "completed"}) do
    %{claimed: 1, completed: 1, needs_confirmation: 0, failed: 0, skipped: 0}
  end

  defp summary_for_run(%Run{status: "needs_confirmation"}) do
    %{claimed: 1, completed: 0, needs_confirmation: 1, failed: 0, skipped: 0}
  end

  defp summary_for_run(%Run{status: "failed"}) do
    %{claimed: 1, completed: 0, needs_confirmation: 0, failed: 1, skipped: 0}
  end

  defp summary_for_run(%Run{status: "skipped"}) do
    %{claimed: 1, completed: 0, needs_confirmation: 0, failed: 0, skipped: 1}
  end

  defp summary_for_run(_run),
    do: %{claimed: 1, completed: 0, needs_confirmation: 0, failed: 0, skipped: 0}

  defp emit_job_signal(kind, job, run, extra \\ %{}) do
    type = Map.fetch!(@job_signals, kind)

    case Signal.new(type, signal_data(job, run, extra),
           source: "/allbert/jobs/#{job.id}",
           subject: job.user_id
         ) do
      {:ok, signal} -> Signals.log(signal)
      {:error, reason} -> Logger.warning("could not emit #{type}: #{inspect(reason)}")
    end
  end

  defp signal_data(job, run, extra) do
    %{
      job_id: job.id,
      run_id: run && run.id,
      trigger: run && run.trigger,
      user_id: job.user_id,
      operator_id: job.operator_id,
      thread_id: (run && run.thread_id) || job.thread_id,
      session_id: job.session_id,
      app_id: job.app_id,
      due_at: run && run.due_at,
      started_at: run && run.started_at,
      finished_at: run && run.finished_at,
      status: run && run.status,
      metadata: Signals.redact(extra)
    }
  end

  defp cleanup_stale_runs_for_state(state, now) do
    stale_before = DateTime.add(now, -state.stale_run_ms, :millisecond)
    Jobs.fail_stale_running_runs(stale_before)
  end

  defp schedule_tick(delay_ms) do
    Process.send_after(self(), :tick, delay_ms)
  end

  defp base_summary(policy) do
    %{policy: policy, claimed: 0, completed: 0, needs_confirmation: 0, failed: 0, skipped: 0}
  end

  defp merge_summary(left, right) do
    Map.merge(left, right, fn
      :policy, policy, _other -> policy
      _key, a, b -> a + b
    end)
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
