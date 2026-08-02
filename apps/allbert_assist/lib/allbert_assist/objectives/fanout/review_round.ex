defmodule AllbertAssist.Objectives.Fanout.ReviewRound do
  @moduledoc """
  Owner-scoped concurrent execution for one two-critic review round.

  Each critic runs in a separate linked and monitored Task and executes one pure
  `CriticAgent` command. This module receives tagged Task results under one
  monotonic deadline and brutally stops remaining siblings on cancellation,
  deadline exhaustion, or the first infrastructure failure. It starts no
  supervisor child, durable Objective, queue, or AgentServer.
  """

  alias AllbertAssist.Objectives.Fanout.{CriticAgent, ReviewProtocol}
  alias AllbertAssist.Objectives.Runs.CancelToken

  @poll_interval_ms 10

  @doc "Run one bounded two-group critic round and return content-free merged evidence."
  @spec run(ReviewProtocol.t(), map(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def run(protocol, sources, candidate, context, opts \\ [])

  def run(%ReviewProtocol{} = protocol, sources, candidate, context, opts)
      when is_map(sources) and is_binary(candidate) and is_map(context) and is_list(opts) do
    with :ok <- active(context),
         {:ok, source_bindings} <- ReviewProtocol.bind_sources(sources, candidate),
         {:ok, implementation} <- critic_implementation(opts),
         {:ok, deadline} <- deadline(opts) do
      tasks = start_critics(protocol, source_bindings, context, implementation)
      await(protocol, source_bindings, context, deadline, pending(tasks), [])
    end
  end

  def run(_protocol, _sources, _candidate, _context, _opts),
    do: {:error, :invalid_review_round_input}

  defp start_critics(protocol, source_bindings, context, implementation) do
    Enum.map(ReviewProtocol.group_ids(protocol), fn group_id ->
      task =
        Task.async(fn ->
          guarded_assess(protocol, group_id, source_bindings, context, implementation)
        end)

      {group_id, task}
    end)
  end

  defp guarded_assess(protocol, group_id, source_bindings, context, implementation) do
    try do
      CriticAgent.assess(protocol, group_id, source_bindings, context, implementation)
    rescue
      _exception -> {:error, :critic_process_failed}
    catch
      :exit, _reason -> {:error, :critic_process_failed}
      _kind, _reason -> {:error, :critic_process_failed}
    end
  end

  defp pending(tasks) do
    Map.new(tasks, fn {group_id, task} ->
      {task.ref, %{group_id: group_id, task: task}}
    end)
  end

  defp await(protocol, source_bindings, _context, _deadline, pending, results)
       when map_size(pending) == 0,
       do: ReviewProtocol.merge(protocol, results, source_bindings)

  defp await(protocol, source_bindings, context, deadline, pending, results) do
    with :ok <- active(context),
         {:ok, remaining} <- remaining(deadline) do
      receive do
        {ref, result} when is_map_key(pending, ref) ->
          %{group_id: group_id, task: task} = Map.fetch!(pending, ref)
          Process.demonitor(task.ref, [:flush])
          pending = Map.delete(pending, ref)

          case result do
            {:ok, %{"group_id" => ^group_id} = group_result} ->
              await(
                protocol,
                source_bindings,
                context,
                deadline,
                pending,
                [group_result | results]
              )

            {:ok, _wrong_group} ->
              stop_all(pending)
              {:error, :invalid_critic_assessment}

            {:error, reason} when is_atom(reason) ->
              stop_all(pending)
              {:error, reason}

            _invalid ->
              stop_all(pending)
              {:error, :invalid_critic_result}
          end

        {:DOWN, ref, :process, _pid, _reason} when is_map_key(pending, ref) ->
          pending = Map.delete(pending, ref)
          stop_all(pending)
          {:error, :critic_process_failed}
      after
        min(remaining, @poll_interval_ms) ->
          await(protocol, source_bindings, context, deadline, pending, results)
      end
    else
      {:error, reason} ->
        stop_all(pending)
        {:error, reason}
    end
  end

  defp active(context) do
    case CancelToken.checkpoint(context) do
      :ok -> :ok
      :cancelled -> {:error, :review_cancelled}
    end
  end

  defp deadline(opts) do
    now = System.monotonic_time(:millisecond)

    case Keyword.fetch(opts, :deadline_monotonic_ms) do
      {:ok, value} when is_integer(value) and value > now -> {:ok, value}
      {:ok, value} when is_integer(value) -> {:error, :review_deadline_exhausted}
      :error -> {:error, :invalid_review_deadline}
      _invalid -> {:error, :invalid_review_deadline}
    end
  end

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      value when value > 0 -> {:ok, value}
      _exhausted -> {:error, :review_deadline_exhausted}
    end
  end

  defp critic_implementation(opts) do
    case Keyword.fetch(opts, :critic_implementation) do
      {:ok, implementation} when is_atom(implementation) -> {:ok, implementation}
      _missing_or_invalid -> {:error, :invalid_critic_implementation}
    end
  end

  defp stop_all(pending) do
    Enum.each(pending, fn {_ref, %{task: task}} ->
      _ = Task.shutdown(task, :brutal_kill)
    end)

    :ok
  end
end
