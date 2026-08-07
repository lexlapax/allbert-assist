defmodule AllbertAssist.Jobs.Scheduler.Executor do
  @moduledoc """
  Durable scheduled-job polling and execution logic.

  The scheduler agent calls this module for each tick. SQLite job and run rows
  stay authoritative; the agent state keeps only runtime configuration and
  diagnostics.
  """

  require Logger

  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Runner
  alias AllbertAssist.Pack.EffectGuard
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

  @doc false
  def build_state(opts) when is_list(opts) do
    scheduler_config = Application.get_env(:allbert_assist, AllbertAssist.Jobs.Scheduler, [])

    %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      initial_delay_ms: Keyword.get(opts, :initial_delay_ms, @default_initial_delay_ms),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      stale_run_ms: Keyword.get(opts, :stale_run_ms, @default_stale_run_ms),
      enabled?: Keyword.get(opts, :enabled?, true),
      poll_on_start?: Keyword.get(opts, :poll_on_start?, true),
      cleanup_on_start?: Keyword.get(opts, :cleanup_on_start?, true),
      managed_reconcile_on_start?:
        Keyword.get(
          opts,
          :managed_reconcile_on_start?,
          Keyword.get(scheduler_config, :managed_reconcile_on_start?, true)
        ),
      last_tick_at: nil,
      last_summary: nil,
      last_error: nil,
      last_command: :rebuild,
      last_result: {:ok, :rebuilt}
    }
  end

  @doc false
  def maybe_reconcile_managed(%{managed_reconcile_on_start?: true}),
    do: reconcile_managed_if_ready()

  def maybe_reconcile_managed(_state), do: {:ok, []}

  @doc false
  def maybe_cleanup_on_start(state, now) do
    with {:ok, epoch} <- EffectGuard.admit_ready(),
         :ok <- EffectGuard.validate(epoch) do
      maybe_cleanup_on_start(state, now, epoch)
    else
      {:error, _reason} -> {:ok, 0}
    end
  end

  defp maybe_cleanup_on_start(state, now, epoch) do
    if state.cleanup_on_start?,
      do: cleanup_stale_runs_for_state(state, now, epoch),
      else: {:ok, 0}
  end

  @doc false
  def poll_once(%{enabled?: false}, _now) do
    {:ok, base_summary("disabled")}
  end

  def poll_once(state, now) when is_map(state) do
    with {:ok, epoch} <- EffectGuard.admit_ready(),
         :ok <- EffectGuard.validate(epoch) do
      poll_once(state, now, epoch)
    else
      {:error, _reason} -> {:error, :product_not_ready}
    end
  end

  def poll_once(state, now, epoch) when is_map(state) do
    case Settings.get("jobs.schedule_policy") do
      {:ok, "operator_approved"} ->
        run_due_jobs(state, now, epoch)

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

  @doc false
  def cleanup_stale_runs_for_state(state, now) when is_map(state) do
    with {:ok, epoch} <- EffectGuard.admit_ready(),
         :ok <- EffectGuard.validate(epoch) do
      cleanup_stale_runs_for_state(state, now, epoch)
    else
      {:error, _reason} -> {:error, :product_not_ready}
    end
  end

  def cleanup_stale_runs_for_state(state, now, epoch) when is_map(state) do
    stale_before = DateTime.add(now, -state.stale_run_ms, :millisecond)

    with :ok <- EffectGuard.validate(epoch) do
      Jobs.fail_stale_running_runs(stale_before)
    else
      {:error, _reason} -> {:error, :product_not_ready}
    end
  end

  @doc false
  def utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp run_due_jobs(state, now, epoch) do
    now
    |> Jobs.due_jobs(state.batch_size)
    |> Enum.reduce(base_summary("operator_approved"), fn job, summary ->
      merge_summary(summary, run_due_job(job, now, epoch))
    end)
    |> then(&{:ok, &1})
  end

  defp run_due_job(%Job{} = job, now, epoch) do
    case EffectGuard.validate(epoch) do
      :ok -> run_due_job_after_validation(job, now, epoch)
      {:error, _reason} -> skipped_product_not_ready()
    end
  end

  defp run_due_job_after_validation(%Job{} = job, now, epoch) do
    case Jobs.claim_due_job(job, now) do
      {:ok, %Run{} = run} ->
        emit_job_signal(:due, job, run)
        emit_job_signal(:started, job, run, %{started_at: utc_now()})
        execute_claimed_run(job, run, epoch)

      {:ok, %{outcome: :coalesced} = admission} ->
        emit_job_signal(:skipped, job, nil, %{reason: "coalesced", admission: admission})
        %{claimed: 0, completed: 0, needs_confirmation: 0, failed: 0, skipped: 1}

      {:error, reason} ->
        emit_job_signal(:skipped, job, nil, %{reason: inspect(reason)})
        %{claimed: 0, completed: 0, needs_confirmation: 0, failed: 0, skipped: 1}
    end
  end

  defp execute_claimed_run(job, run, epoch) do
    case EffectGuard.validate(epoch) do
      :ok -> execute_claimed_run_after_validation(job, run, epoch)
      {:error, _reason} -> skipped_product_not_ready()
    end
  end

  defp execute_claimed_run_after_validation(job, run, epoch) do
    case Runner.execute_run(job, run, allbert_pack_epoch: epoch) do
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
    unless Managed.managed?(job) do
      case Jobs.advance_next_due(job) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "could not advance scheduled job next_due_at job_id=#{job.id}: #{inspect(reason)}"
          )
      end
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

  defp skipped_product_not_ready,
    do: %{claimed: 0, completed: 0, needs_confirmation: 0, failed: 0, skipped: 1}

  defp reconcile_managed_if_ready do
    with {:ok, epoch} <- EffectGuard.admit_ready(),
         :ok <- EffectGuard.validate(epoch) do
      Managed.reconcile("local")
    else
      {:error, _reason} -> {:ok, []}
    end
  end

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

  defp base_summary(policy) do
    %{policy: policy, claimed: 0, completed: 0, needs_confirmation: 0, failed: 0, skipped: 0}
  end

  defp merge_summary(left, right) do
    Map.merge(left, right, fn
      :policy, policy, _other -> policy
      _key, a, b -> a + b
    end)
  end
end
