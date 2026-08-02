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
  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Runs.CancelToken

  @poll_interval_ms 10
  @reviewer_config_aggregate_domain "allbert:fanout-reviewer-config-aggregate:v1\0"
  @result_keys [
    :assessment_sha256,
    :assessments,
    :critic_group_count,
    :group_results,
    :outcome,
    :provider_call_count,
    :review_protocol_version,
    :reviewer_config_sha256,
    :revision_rule_ids,
    :rule_group_catalog_sha256,
    :rule_group_catalog_version,
    :source_sha256
  ]

  @doc "Run one bounded two-group critic round and return content-free merged evidence."
  @spec run(ReviewProtocol.t(), map(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, {:review_round_failed, atom(), non_neg_integer()}}
  def run(protocol, sources, candidate, context, opts \\ [])

  def run(%ReviewProtocol{} = protocol, sources, candidate, context, opts)
      when is_map(sources) and is_binary(candidate) and is_map(context) and is_list(opts) do
    {context, attempt_counter} = ProviderAttempt.attach(context)

    result =
      with :ok <- active(context),
           {:ok, source_bindings} <- ReviewProtocol.bind_sources(sources, candidate),
           {:ok, implementation} <- critic_implementation(opts),
           {:ok, deadline} <- deadline(opts) do
        tasks = start_critics(protocol, source_bindings, context, implementation)
        await(protocol, source_bindings, context, deadline, pending(tasks), [])
      end

    bind_attempt_count(result, attempt_counter)
  end

  def run(_protocol, _sources, _candidate, _context, _opts),
    do: {:error, {:review_round_failed, :invalid_review_round_input, 0}}

  @doc false
  @spec note_provider_attempt(map()) :: :ok | {:error, :invalid_review_attempt_counter}
  def note_provider_attempt(context) do
    case ProviderAttempt.mark(context) do
      :ok -> :ok
      {:error, :invalid_provider_attempt_counter} -> {:error, :invalid_review_attempt_counter}
    end
  end

  @doc "Revalidate one merged result against exact current source bytes and configuration."
  @spec validate_result(ReviewProtocol.t(), map(), String.t(), map(), keyword()) ::
          :ok | {:error, :invalid_review_round_result}
  def validate_result(protocol, sources, candidate, result, opts \\ [])

  def validate_result(%ReviewProtocol{} = protocol, sources, candidate, result, opts)
      when is_map(sources) and is_binary(candidate) and is_map(result) and is_list(opts) do
    expected_config = Keyword.get(opts, :expected_reviewer_config_sha256)

    with true <- Enum.sort(Map.keys(result)) == Enum.sort(@result_keys),
         true <- sha256?(result.reviewer_config_sha256),
         true <- is_nil(expected_config) or result.reviewer_config_sha256 == expected_config,
         true <- result.provider_call_count == 2,
         {:ok, source_bindings} <- ReviewProtocol.bind_sources(sources, candidate),
         {:ok, merged} <- ReviewProtocol.merge(protocol, result.group_results, source_bindings),
         expected =
           merged
           |> Map.put(:reviewer_config_sha256, result.reviewer_config_sha256)
           |> Map.put(:provider_call_count, 2),
         true <- expected == result do
      :ok
    else
      _invalid -> {:error, :invalid_review_round_result}
    end
  end

  def validate_result(_protocol, _sources, _candidate, _result, _opts),
    do: {:error, :invalid_review_round_result}

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
       do: finalize(protocol, source_bindings, results)

  defp await(protocol, source_bindings, context, deadline, pending, results) do
    with :ok <- active(context),
         {:ok, remaining} <- remaining(deadline) do
      receive do
        {ref, result} when is_map_key(pending, ref) ->
          %{group_id: group_id, task: task} = Map.fetch!(pending, ref)
          Process.demonitor(task.ref, [:flush])
          pending = Map.delete(pending, ref)

          case result do
            {:ok,
             %{
               assessment: %{"group_id" => ^group_id} = group_result,
               reviewer_config_sha256: reviewer_config_sha256
             }} ->
              await(
                protocol,
                source_bindings,
                context,
                deadline,
                pending,
                [
                  %{
                    group_id: group_id,
                    assessment: group_result,
                    reviewer_config_sha256: reviewer_config_sha256
                  }
                  | results
                ]
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

  defp finalize(protocol, source_bindings, results) do
    ordered_results = order_results(protocol, results)

    with {:ok, merged} <-
           ReviewProtocol.merge(
             protocol,
             Enum.map(ordered_results, & &1.assessment),
             source_bindings
           ) do
      aggregate_input = %{
        "review_protocol_version" => protocol.review_protocol_version,
        "rule_group_catalog_version" => protocol.rule_group_catalog_version,
        "rule_group_catalog_sha256" => protocol.rule_group_catalog_sha256,
        "critics" =>
          Enum.map(ordered_results, fn result ->
            %{
              "group_id" => result.group_id,
              "reviewer_config_sha256" => result.reviewer_config_sha256
            }
          end)
      }

      {:ok,
       Map.put(
         merged,
         :reviewer_config_sha256,
         sha256(@reviewer_config_aggregate_domain <> CanonicalJSON.encode(aggregate_input))
       )}
    end
  end

  defp bind_attempt_count({:ok, result}, attempt_counter) do
    case ProviderAttempt.count(attempt_counter) do
      2 -> {:ok, Map.put(result, :provider_call_count, 2)}
      _invalid -> round_failure(:invalid_review_provider_call_count, attempt_counter)
    end
  end

  defp bind_attempt_count({:error, reason}, attempt_counter) when is_atom(reason),
    do: round_failure(reason, attempt_counter)

  defp bind_attempt_count(_invalid, attempt_counter),
    do: round_failure(:invalid_review_round_result, attempt_counter)

  defp round_failure(reason, attempt_counter),
    do: {:error, {:review_round_failed, reason, ProviderAttempt.count(attempt_counter)}}

  defp order_results(protocol, results) do
    by_group = Map.new(results, &{&1.group_id, &1})
    Enum.map(ReviewProtocol.group_ids(protocol), &Map.fetch!(by_group, &1))
  end

  defp stop_all(pending) do
    Enum.each(pending, fn {_ref, %{task: task}} ->
      _ = Task.shutdown(task, :brutal_kill)
    end)

    :ok
  end

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :lower) do
      {:ok, bytes} -> byte_size(bytes) == 32
      :error -> false
    end
  end

  defp sha256?(_value), do: false
end
