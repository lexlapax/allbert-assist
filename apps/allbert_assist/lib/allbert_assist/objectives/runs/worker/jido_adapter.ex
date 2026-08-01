defmodule AllbertAssist.Objectives.Runs.Worker.JidoAdapter do
  @moduledoc """
  Temporary bounded Jido Adapter for a clean DirectAnswer Objective child.

  A linked task hosts one pure `Jido.Agent.cmd/3` lifecycle and is terminated
  before the Adapter returns. We intentionally do not use AgentServer here:
  its signal-call action runs in a separately supervised task, which cannot be
  tied to this RunServer's timeout or exit. The existing RunServer/cancel-token
  relationship therefore remains the live cancellation owner; no worker
  process or Jido state is durable completion evidence.
  """

  @behaviour AllbertAssist.Objectives.Runs.Worker.Adapter

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Objectives.Runs.Worker.{Agent, QualityPolicy, ReqLLMReviewer}
  alias AllbertAssist.Objectives.Runs.Worker.Commands.{Execute, ReviewAndRevise}

  @default_timeout_ms 30_000
  @maximum_timeout_ms 120_000
  @fanout_worker_policy %{
    version: 1,
    provider_failover: :disabled,
    conversation_fanout: :disabled
  }

  @impl true
  def run(DirectAnswer, params, context, opts) do
    with :ok <- active(context),
         {:ok, quality} <- quality_context(context) do
      timeout = bounded_timeout(opts, context)
      context = put_model_limits(context, timeout, quality)
      worker = Task.async(fn -> execute(params, context, quality, opts) end)
      emit_start(worker.pid, context)
      await(worker, timeout)
    end
  end

  def run(_action_module, _params, _context, _opts), do: {:error, :unsupported_jido_action}

  defp execute(params, context, quality, opts) do
    state = initial_state(context, quality)

    agent =
      Agent.new(
        id: worker_id(context),
        state: state
      )

    payload = %{
      action_module: DirectAnswer,
      action_params: action_params(params, quality),
      runner_context: context
    }

    # Timeout zero keeps Jido.Exec inside this owned worker process. The outer
    # Adapter timeout below is the one bounded lifecycle budget and can kill
    # the whole Runner/provider call without leaving a supervisor-owned task.
    {agent, _directives} =
      Agent.cmd(agent, {Execute, payload}, timeout: 0, __jido_instance__: AllbertAssist.Jido)

    continue(agent, context, quality, opts)
  end

  defp continue(agent, _context, :legacy, _opts) do
    case agent.state do
      %{last_result: {:ok, response}} -> {:ok, response}
      %{last_result: {:error, reason}} -> {:error, reason}
      _missing -> {:error, :missing_worker_result}
    end
  end

  defp continue(%{state: %{status: :draft}} = agent, context, %{contract: contract}, opts) do
    with :ok <- active(context) do
      review_payload = %{
        reviewer: Keyword.get(opts, :quality_reviewer, ReqLLMReviewer),
        task_contract: contract,
        runner_context: context
      }

      {agent, _directives} =
        Agent.cmd(
          agent,
          {ReviewAndRevise, review_payload},
          timeout: 0,
          __jido_instance__: AllbertAssist.Jido
        )

      case active(context) do
        :ok -> accepted_result(agent.state)
        {:error, reason} -> unresolved_error(agent.state, reason)
      end
    else
      {:error, reason} -> unresolved_error(agent.state, reason)
    end
  end

  defp continue(%{state: state}, _context, %{contract: _contract}, _opts),
    do: unresolved_error(state, Map.get(state, :error, :quality_draft_unresolved))

  defp accepted_result(%{
         status: :accepted,
         last_result: {:ok, %{response: response, quality_receipt: receipt}}
       }),
       do: {:ok, %{response: response, quality_receipt: receipt}}

  defp accepted_result(state),
    do: unresolved_error(state, Map.get(state, :error, :quality_review_unresolved))

  defp unresolved_error(state, reason) do
    {:error,
     {:fanout_worker_unresolved,
      %{
        provider_call_count: Map.get(state, :provider_call_count, 0),
        reason: reason
      }}}
  end

  defp quality_context(%{fanout_grounding: %{source: source} = grounding})
       when source in [:conversation_manager, :counted_protocol, :operator_steered] do
    with {:ok, contract} <- QualityPolicy.build(grounding),
         {:ok, digest} <- QualityPolicy.digest(contract),
         {:ok, draft_prompt} <- QualityPolicy.draft_prompt(contract) do
      {:ok, %{contract: contract, digest: digest, draft_prompt: draft_prompt}}
    end
  end

  defp quality_context(%{fanout_grounding: %{source: :untrusted}}),
    do: {:error, :invalid_quality_task_grounding}

  defp quality_context(%{fanout_grounding: %{source: source}})
       when source in [:ordinary, :legacy_ordinary],
       do: {:ok, :legacy}

  defp quality_context(context) when not is_map_key(context, :fanout_grounding),
    do: {:ok, :legacy}

  defp quality_context(_context), do: {:error, :invalid_quality_task_grounding}

  defp initial_state(context, :legacy) do
    %{
      status: :ready,
      objective_id: Map.get(context, :objective_id),
      step_id: Map.get(context, :step_id),
      last_command: nil,
      last_result: nil
    }
  end

  defp initial_state(context, %{contract: contract, digest: digest}) do
    %{
      status: :ready,
      objective_id: Map.get(context, :objective_id),
      step_id: Map.get(context, :step_id),
      provider_call_count: 0,
      task_contract: contract,
      task_contract_sha256: digest,
      last_command: nil,
      last_result: nil
    }
  end

  defp action_params(params, :legacy), do: params
  defp action_params(params, %{draft_prompt: prompt}), do: Map.put(params, :text, prompt)

  defp active(context) do
    case CancelToken.checkpoint(context) do
      :ok -> :ok
      :cancelled -> {:error, :cancelled}
    end
  end

  defp await(worker, timeout) do
    case Task.yield(worker, timeout) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:worker_exit, reason}}

      nil ->
        _ = Task.shutdown(worker, :brutal_kill)
        {:error, :worker_timeout}
    end
  end

  defp emit_start(worker, context) do
    :telemetry.execute(
      [:allbert_assist, :objectives, :worker, :start],
      %{system_time: System.system_time()},
      %{
        adapter: :jido,
        worker_pid: worker,
        objective_id: Map.get(context, :objective_id),
        step_id: Map.get(context, :step_id)
      }
    )
  end

  defp worker_id(context) do
    [
      "objective-worker",
      Map.get(context, :objective_id, "unframed"),
      Map.get(context, :step_id, "unselected"),
      System.unique_integer([:positive, :monotonic])
    ]
    |> Enum.join("-")
  end

  defp bounded_timeout(opts, context) do
    configured =
      case Keyword.get(opts, :worker_timeout_ms, @default_timeout_ms) do
        timeout when is_integer(timeout) and timeout > 0 -> min(timeout, @maximum_timeout_ms)
        _invalid -> @default_timeout_ms
      end

    case Map.get(context, :fanout_deadline_unix_ms) do
      deadline when is_integer(deadline) ->
        min(configured, max(deadline - System.system_time(:millisecond), 1))

      _legacy ->
        configured
    end
  end

  defp put_model_limits(context, timeout, :legacy) do
    context
    |> Map.put(:model_max_output_tokens, 512)
    |> Map.put(:model_timeout_ms, timeout)
  end

  defp put_model_limits(context, timeout, %{contract: _contract}) do
    context
    |> Map.put(:model_max_output_tokens, 512)
    |> Map.put(:model_timeout_ms, timeout)
    |> Map.put(
      :fanout_worker_deadline_monotonic_ms,
      System.monotonic_time(:millisecond) + timeout
    )
    |> Map.put(:fanout_worker_policy, @fanout_worker_policy)
  end
end
