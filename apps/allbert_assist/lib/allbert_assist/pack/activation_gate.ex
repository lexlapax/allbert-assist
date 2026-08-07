defmodule AllbertAssist.Pack.ActivationGate do
  @moduledoc false

  use GenServer

  alias AllbertAssist.Pack.{ActivationContext, ActivationGuard, Readiness}

  require Logger

  @retry_ms 100
  @effect_shutdown_timeout_ms 5_000

  defstruct readiness: Readiness,
            readiness_opts: [],
            pack_id: "allbert_assist",
            effect_supervisor: AllbertAssist.Pack.ResidualEffectSupervisor,
            effect_supervisor_opts: [],
            activation_worker_after_result: nil,
            subscription_ref: nil,
            barrier_pid: nil,
            barrier_monitor: nil,
            activation: nil,
            effect_pid: nil,
            effect_monitor: nil,
            retiring_effect: nil,
            retry_ref: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       readiness: Keyword.get(opts, :readiness, Readiness),
       readiness_opts: Keyword.get(opts, :readiness_opts, []),
       pack_id: Keyword.get(opts, :pack_id, "allbert_assist"),
       effect_supervisor:
         Keyword.get(opts, :effect_supervisor, AllbertAssist.Pack.ResidualEffectSupervisor),
       effect_supervisor_opts: Keyword.get(opts, :effect_supervisor_opts, []),
       activation_worker_after_result: Keyword.get(opts, :activation_worker_after_result),
       retry_ref: schedule_subscribe(0)
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  @impl true
  def handle_info(:subscribe, %{barrier_pid: nil} = state) do
    case apply(state.readiness, :subscribe, [state.pack_id, state.readiness_opts]) do
      {:ok, %{barrier_pid: barrier_pid, subscription_ref: subscription_ref}} ->
        {:noreply,
         %{
           state
           | barrier_pid: barrier_pid,
             subscription_ref: subscription_ref,
             barrier_monitor: Process.monitor(barrier_pid),
             retry_ref: nil
         }}

      {:error, _reason} ->
        {:noreply, %{state | retry_ref: schedule_subscribe(@retry_ms)}}
    end
  end

  def handle_info(:subscribe, state), do: {:noreply, state}

  def handle_info(
        {:allbert_pack_activate, barrier_pid, subscription_ref, snapshot_digest},
        %{barrier_pid: barrier_pid, subscription_ref: subscription_ref, activation: nil} = state
      ) do
    context = %ActivationContext{
      schema_version: 1,
      pack_id: state.pack_id,
      gate_pid: self(),
      barrier_pid: barrier_pid,
      subscription_ref: subscription_ref,
      snapshot_digest: snapshot_digest
    }

    gate = self()

    {:ok, worker_pid} =
      Task.start(fn ->
        result = start_effect_supervisor(context, state)
        send(gate, {:activation_finished, context, result})
        run_after_result_hook(state.activation_worker_after_result, result)

        case result do
          {:ok, effect_pid} -> Process.unlink(effect_pid)
          _other -> :ok
        end
      end)

    # A normal worker exit is an explicit ACK precondition: it proves the
    # activation-owned subtree finished starting before the barrier is opened.
    activation = %{
      context: context,
      worker_monitor: Process.monitor(worker_pid),
      result: nil,
      down?: false,
      cancelled?: false
    }

    {:noreply, %{state | activation: activation}}
  end

  def handle_info(
        {:activation_finished, context, result},
        %{activation: %{context: context} = activation} = state
      ) do
    state = %{state | activation: %{activation | result: result}}
    {:noreply, finish_activation_transition(state)}
  end

  def handle_info({:activation_finished, _context, {:ok, effect_pid}}, state)
      when is_pid(effect_pid) do
    terminate_effect(effect_pid)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{activation: %{worker_monitor: monitor} = activation} = state
      ) do
    state = %{state | activation: %{activation | down?: true}}

    case {activation.cancelled?, reason, activation.result} do
      {true, _reason, nil} ->
        {:noreply, resume_cancelled_activation(%{state | activation: nil})}

      {true, _reason, _result} ->
        {:noreply, finish_cancelled_activation(state)}

      {false, :normal, _result} ->
        {:noreply, maybe_acknowledge(state)}

      {false, _other, _result} ->
        {:noreply, fail_activation({:activation_worker_down, pid, reason}, state)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{barrier_monitor: monitor} = state) do
    {:noreply, reset_after_barrier_loss(state)}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        %{retiring_effect: %{pid: pid, monitor: monitor} = retiring} = state
      ) do
    Process.cancel_timer(retiring.timeout_ref)
    {:noreply, resume_after_effect_retirement(%{state | retiring_effect: nil})}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{effect_monitor: monitor} = state) do
    {:stop, :effect_supervisor_down, state}
  end

  def handle_info({:EXIT, pid, _reason}, %{retiring_effect: %{pid: pid}} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, pid, _reason}, %{effect_pid: pid} = state),
    do: {:stop, :effect_supervisor_down, state}

  def handle_info(
        {:force_terminate_effect, effect_pid},
        %{retiring_effect: %{pid: effect_pid}} = state
      ) do
    if Process.alive?(effect_pid), do: Process.exit(effect_pid, :kill)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_effect_supervisor(context, state) do
    carrier = [allbert_pack_activation: context]

    with :ok <- ActivationGuard.validate(carrier) do
      opts = Keyword.put(state.effect_supervisor_opts, :allbert_pack_activation, context)

      case state.effect_supervisor.start_link(opts) do
        {:ok, _effect_pid} = result ->
          result

        other ->
          other
      end
    end
  end

  defp maybe_acknowledge(
         %{activation: %{down?: true, result: {:ok, effect_pid}, context: context}} = state
       ) do
    Process.link(effect_pid)

    case apply(state.readiness, :ack, [
           context.subscription_ref,
           context.snapshot_digest,
           [server: context.barrier_pid]
         ]) do
      :ok ->
        %{
          state
          | activation: nil,
            effect_pid: effect_pid,
            effect_monitor: Process.monitor(effect_pid)
        }

      {:error, reason} ->
        fail_activation({:activation_ack_failed, reason}, %{state | effect_pid: effect_pid})
    end
  end

  defp maybe_acknowledge(%{activation: %{down?: true, result: {:error, reason}}} = state),
    do: fail_activation(reason, state)

  defp maybe_acknowledge(state), do: state

  defp finish_activation_transition(%{activation: %{cancelled?: true}} = state),
    do: finish_cancelled_activation(state)

  defp finish_activation_transition(state), do: maybe_acknowledge(state)

  defp finish_cancelled_activation(state) do
    state = begin_cancelled_effect_retirement(state)

    case state.activation do
      %{down?: true} -> resume_cancelled_activation(%{state | activation: nil})
      _still_running -> state
    end
  end

  defp begin_cancelled_effect_retirement(
         %{activation: %{result: {:ok, effect_pid}}, retiring_effect: nil, effect_pid: nil} =
           state
       ) do
    if Process.alive?(effect_pid) do
      Process.link(effect_pid)

      state
      |> Map.put(:effect_pid, effect_pid)
      |> Map.put(:effect_monitor, Process.monitor(effect_pid))
      |> retire_effect_before_resubscribe()
    else
      state
    end
  end

  defp begin_cancelled_effect_retirement(state), do: state

  defp resume_cancelled_activation(%{retiring_effect: retiring} = state)
       when not is_nil(retiring),
       do: state

  defp resume_cancelled_activation(state), do: retire_effect_before_resubscribe(state)

  defp fail_activation(reason, %{activation: %{context: context}} = state) do
    Logger.warning(
      "Pack activation failed pack_id=#{state.pack_id} reason=#{inspect(redact_activation_reason(reason))}"
    )

    _ =
      apply(state.readiness, :nack, [
        context.subscription_ref,
        context.snapshot_digest,
        reason,
        [server: context.barrier_pid]
      ])

    reset_after_barrier_loss(state)
  end

  defp redact_activation_reason({:shutdown, {:failed_to_start_child, child, reason}}) do
    {path, failure_tag} = failed_child_path(child, reason)
    {:effect_child_failed, path, failure_tag}
  end

  defp redact_activation_reason({:activation_ack_failed, _reason}),
    do: :activation_ack_failed

  defp redact_activation_reason(
         {:activation_worker_down, _pid, {:shutdown, {:failed_to_start_child, child, reason}}}
       ) do
    {path, failure_tag} = failed_child_path(child, reason)
    {:activation_worker_child_failed, path, failure_tag}
  end

  defp redact_activation_reason({:activation_worker_down, _pid, {exception, _stacktrace}})
       when is_exception(exception),
       do: {:activation_worker_exception, exception.__struct__}

  defp redact_activation_reason({:activation_worker_down, _pid, reason}) when is_atom(reason),
    do: {:activation_worker_down, reason}

  defp redact_activation_reason({:activation_worker_down, _pid, _reason}),
    do: :activation_worker_down

  defp redact_activation_reason(_reason), do: :effect_activation_failed

  defp stable_child_id(child) when is_atom(child), do: child
  defp stable_child_id(_child), do: :unknown

  defp failed_child_path(child, {:shutdown, {:failed_to_start_child, nested, reason}}) do
    {path, failure_tag} = failed_child_path(nested, reason)
    {[stable_child_id(child) | path], failure_tag}
  end

  defp failed_child_path(child, reason),
    do: {[stable_child_id(child)], stable_failure_tag(reason)}

  defp stable_failure_tag(reason) when is_atom(reason), do: reason
  defp stable_failure_tag({tag, _value}) when is_atom(tag), do: tag
  defp stable_failure_tag({tag, _value, _extra}) when is_atom(tag), do: tag
  defp stable_failure_tag(_reason), do: :unknown

  defp reset_after_barrier_loss(state) do
    if is_reference(state.barrier_monitor), do: Process.demonitor(state.barrier_monitor, [:flush])

    state = %{
      state
      | subscription_ref: nil,
        barrier_pid: nil,
        barrier_monitor: nil,
        retry_ref: nil
    }

    case state.activation do
      nil ->
        retire_effect_before_resubscribe(state)

      activation ->
        state
        |> Map.put(:activation, %{activation | cancelled?: true})
        |> finish_cancelled_activation()
    end
  end

  defp schedule_subscribe(delay), do: Process.send_after(self(), :subscribe, delay)

  # A replacement barrier must never observe a still-live subtree from the
  # retired epoch. Keep the monitor through the graceful deadline and only
  # resubscribe after DOWN proves the old effect owner is gone.
  defp retire_effect_before_resubscribe(%{retiring_effect: retiring} = state)
       when not is_nil(retiring),
       do: state

  defp retire_effect_before_resubscribe(%{effect_pid: effect_pid} = state)
       when is_pid(effect_pid) do
    if Process.alive?(effect_pid) do
      Process.unlink(effect_pid)

      monitor =
        if is_reference(state.effect_monitor),
          do: state.effect_monitor,
          else: Process.monitor(effect_pid)

      Process.exit(effect_pid, :shutdown)

      %{
        state
        | effect_pid: nil,
          effect_monitor: nil,
          retiring_effect: %{
            pid: effect_pid,
            monitor: monitor,
            timeout_ref:
              Process.send_after(
                self(),
                {:force_terminate_effect, effect_pid},
                @effect_shutdown_timeout_ms
              )
          },
          retry_ref: nil
      }
    else
      if is_reference(state.effect_monitor), do: Process.demonitor(state.effect_monitor, [:flush])
      resume_after_effect_retirement(%{state | effect_pid: nil, effect_monitor: nil})
    end
  end

  defp retire_effect_before_resubscribe(state), do: resume_after_effect_retirement(state)

  defp resume_after_effect_retirement(state) do
    if is_reference(state.effect_monitor), do: Process.demonitor(state.effect_monitor, [:flush])

    state = %{
      state
      | effect_pid: nil,
        effect_monitor: nil
    }

    case state.activation do
      %{cancelled?: true} ->
        state

      _no_cancelled_activation ->
        %{state | retry_ref: state.retry_ref || schedule_subscribe(@retry_ms)}
    end
  end

  defp terminate_effect(effect_pid), do: Process.exit(effect_pid, :shutdown)

  defp run_after_result_hook(nil, _result), do: :ok
  defp run_after_result_hook(hook, result) when is_function(hook, 1), do: hook.(result)

  defp public_status(state) do
    %{
      phase: if(is_pid(state.effect_pid), do: :ready, else: :collecting),
      pack_id: state.pack_id,
      barrier_pid: state.barrier_pid,
      subscription_ref: state.subscription_ref,
      effect_supervisor: state.effect_pid
    }
  end
end
