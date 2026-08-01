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
  alias AllbertAssist.Objectives.Runs.Worker.Agent
  alias AllbertAssist.Objectives.Runs.Worker.Commands.Execute

  @default_timeout_ms 30_000
  @maximum_timeout_ms 120_000

  @impl true
  def run(DirectAnswer, params, context, opts) do
    with :ok <- active(context) do
      timeout = bounded_timeout(opts, context)
      context = put_model_limits(context, timeout)
      worker = Task.async(fn -> execute(params, context) end)
      emit_start(worker.pid, context)
      await(worker, timeout)
    end
  end

  def run(_action_module, _params, _context, _opts), do: {:error, :unsupported_jido_action}

  defp execute(params, context) do
    agent =
      Agent.new(
        id: worker_id(context),
        state: %{
          status: :ready,
          objective_id: Map.get(context, :objective_id),
          step_id: Map.get(context, :step_id),
          last_command: nil,
          last_result: nil
        }
      )

    payload = %{
      action_module: DirectAnswer,
      action_params: params,
      runner_context: context
    }

    # Timeout zero keeps Jido.Exec inside this owned worker process. The outer
    # Adapter timeout below is the one bounded lifecycle budget and can kill
    # the whole Runner/provider call without leaving a supervisor-owned task.
    {agent, _directives} =
      Agent.cmd(agent, {Execute, payload}, timeout: 0, __jido_instance__: AllbertAssist.Jido)

    case agent.state do
      %{last_result: {:ok, response}} -> {:ok, response}
      %{last_result: {:error, reason}} -> {:error, reason}
      _missing -> {:error, :missing_worker_result}
    end
  end

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

  defp put_model_limits(context, timeout) do
    context
    |> Map.put(:model_max_output_tokens, 512)
    |> Map.put(:model_timeout_ms, timeout)
  end
end
