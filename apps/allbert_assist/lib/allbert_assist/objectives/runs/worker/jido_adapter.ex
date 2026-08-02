defmodule AllbertAssist.Objectives.Runs.Worker.JidoAdapter do
  @moduledoc """
  Bounded Jido Adapter for one DirectAnswer Objective child.

  v1.3 M9.b.6 (ADR 0021 A24): one generation call, then terminalize. The
  draft/review/revise continuation is removed — no model judges model output.

  A linked task hosts one pure `Jido.Agent.cmd/3` lifecycle and is terminated
  before the Adapter returns. We intentionally do not use AgentServer here:
  its signal-call action runs in a separately supervised task, which cannot be
  tied to this RunServer's timeout or exit. The existing RunServer/cancel-token
  relationship therefore remains the live cancellation owner; no worker
  process or Jido state is durable completion evidence.
  """

  @behaviour AllbertAssist.Objectives.Runs.Worker.Adapter

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Objectives.Fanout.EndpointAdmission
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Objectives.Runs.Worker.{Agent, QualityPolicy}
  alias AllbertAssist.Objectives.Runs.Worker.Commands.Execute

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
         {:ok, quality} <- quality_context(context),
         {:ok, bounds} <- bounded_timeout(opts, context, quality) do
      context = put_model_limits(context, bounds, quality)
      endpoint_id = EndpointAdmission.endpoint_id(Map.get(context, :fanout_role_binding))

      worker =
        Task.async(fn ->
          EndpointAdmission.with_endpoint(endpoint_id, bounds.deadline_monotonic_ms, fn ->
            execute(params, context, quality)
          end)
        end)
      emit_start(worker.pid, context)
      await(worker, bounds.deadline_monotonic_ms)
    end
  end

  def run(_action_module, _params, _context, _opts), do: {:error, :unsupported_jido_action}

  defp execute(params, context, quality) do
    state = initial_state(context, quality)

    agent =
      Agent.new(
        id: worker_id(context),
        state: state
      )

    payload = %{
      action_module: DirectAnswer,
      action_params: action_params(params, quality),
      runner_context: draft_context(context, quality)
    }

    # Timeout zero keeps Jido.Exec inside this owned worker process. The outer
    # Adapter timeout below is the one bounded lifecycle budget and can kill
    # the whole Runner/provider call without leaving a supervisor-owned task.
    {agent, _directives} =
      Agent.cmd(agent, {Execute, payload},
        timeout: 0,
        max_retries: 0,
        __jido_instance__: AllbertAssist.Jido
      )

    resolve(agent, context, quality)
  end

  defp resolve(agent, _context, :legacy) do
    case agent.state do
      %{last_result: {:ok, response}} -> {:ok, response}
      %{last_result: {:error, reason}} -> {:error, reason}
      _missing -> {:error, :missing_worker_result}
    end
  end

  defp resolve(agent, context, %{contract: _contract}) do
    case active(context) do
      :ok -> accepted_result(agent.state)
      {:error, reason} -> unresolved_error(agent.state, reason)
    end
  end

  defp accepted_result(%{
         status: :accepted,
         last_result: {:ok, %{response: response, quality_receipt: receipt}}
       }),
       do: {:ok, %{response: response, quality_receipt: receipt}}

  defp accepted_result(state),
    do: unresolved_error(state, Map.get(state, :error, :quality_generation_unresolved))

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

  defp draft_context(context, :legacy), do: context

  defp draft_context(context, %{contract: _contract}),
    do: Map.put(context, :fanout_worker_phase, :generation)

  defp active(context) do
    case CancelToken.checkpoint(context) do
      :ok -> :ok
      :cancelled -> {:error, :cancelled}
    end
  end

  defp await(worker, deadline_monotonic_ms) do
    remaining = deadline_monotonic_ms - System.monotonic_time(:millisecond)

    if remaining > 0 do
      worker
      |> Task.yield(remaining)
      |> resolve_await(worker, deadline_monotonic_ms)
    else
      timeout(worker)
    end
  end

  defp resolve_await({:ok, result}, _worker, deadline_monotonic_ms) do
    if System.monotonic_time(:millisecond) < deadline_monotonic_ms,
      do: result,
      else: {:error, :worker_timeout}
  end

  defp resolve_await({:exit, reason}, _worker, _deadline_monotonic_ms),
    do: {:error, {:worker_exit, reason}}

  defp resolve_await(nil, worker, _deadline_monotonic_ms), do: timeout(worker)

  defp timeout(worker) do
    _ = Task.shutdown(worker, :brutal_kill)
    {:error, :worker_timeout}
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

  defp bounded_timeout(opts, context, :legacy) do
    configured =
      case Keyword.get(opts, :worker_timeout_ms, @default_timeout_ms) do
        timeout when is_integer(timeout) and timeout > 0 -> min(timeout, @maximum_timeout_ms)
        _invalid -> @default_timeout_ms
      end

    timeout_ms =
      case Map.get(context, :fanout_deadline_unix_ms) do
        deadline when is_integer(deadline) ->
          min(configured, max(deadline - System.system_time(:millisecond), 1))

        _legacy ->
          configured
      end

    {:ok,
     %{
       timeout_ms: timeout_ms,
       deadline_monotonic_ms: System.monotonic_time(:millisecond) + timeout_ms
     }}
  end

  defp bounded_timeout(opts, context, %{contract: _contract}) do
    now_unix_ms = System.system_time(:millisecond)
    now_monotonic_ms = System.monotonic_time(:millisecond)

    with deadline when is_integer(deadline) <- Map.get(context, :fanout_deadline_unix_ms),
         remaining when remaining > 0 <- deadline - now_unix_ms do
      timeout_ms =
        case Keyword.fetch(opts, :worker_timeout_ms) do
          {:ok, configured} when is_integer(configured) and configured > 0 ->
            min(configured, remaining)

          _missing_or_invalid ->
            remaining
        end

      {:ok,
       %{
         timeout_ms: timeout_ms,
         deadline_monotonic_ms: now_monotonic_ms + timeout_ms
       }}
    else
      _missing_expired_or_invalid -> {:error, :fanout_plan_deadline_exhausted}
    end
  end

  defp put_model_limits(context, bounds, :legacy) do
    context
    |> Map.put(:model_max_output_tokens, 512)
    |> Map.put(:model_timeout_ms, bounds.timeout_ms)
  end

  defp put_model_limits(context, bounds, %{contract: _contract}) do
    context
    |> Map.put(:model_max_output_tokens, 512)
    |> Map.put(:model_timeout_ms, bounds.timeout_ms)
    |> Map.put(:model_max_retries, 0)
    |> Map.put(:fanout_worker_deadline_monotonic_ms, bounds.deadline_monotonic_ms)
    |> Map.put(:fanout_worker_policy, @fanout_worker_policy)
  end
end
