defmodule AllbertAssist.Execution.ProcessOwner do
  @moduledoc """
  Temporary owner for one authorized OS execution and its captured process group.

  This plain GenServer owns the erlexec control process because its state is a
  small execution lifecycle, not an agent. `run_link/2`, `{group, 0}`, and
  `kill_group` bind owner loss and timeout cleanup to the exact spawned group;
  no pid is reconstructed after owner loss.
  """

  use GenServer, restart: :temporary

  alias AllbertAssist.Execution.OutputBuffer

  @default_kill_grace_ms 5_000

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :execution_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(executable, args, opts \\ []) do
    execution_id = Keyword.get_lazy(opts, :execution_id, &Ecto.UUID.generate/0)
    child_opts = [execution_id: execution_id, executable: executable, args: args, opts: opts]

    with {:ok, pid} <-
           DynamicSupervisor.start_child(
             AllbertAssist.Execution.ProcessOwners,
             {__MODULE__, child_opts}
           ) do
      GenServer.call(pid, :await, :infinity)
    end
  end

  @spec cancel(String.t()) :: {:ok, :cooperative | :os_kill} | {:error, :not_found}
  def cancel(execution_id) when is_binary(execution_id) do
    case Registry.lookup(AllbertAssist.Execution.ProcessRegistry, {:execution, execution_id}) do
      [{pid, _metadata}] -> GenServer.call(pid, :cancel, :infinity)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    execution_id = Keyword.fetch!(opts, :execution_id)
    run_opts = Keyword.fetch!(opts, :opts)

    with {:ok, _} <-
           Registry.register(
             AllbertAssist.Execution.ProcessRegistry,
             {:execution, execution_id},
             %{}
           ),
         {:ok, exec_pid, os_pid} <-
           start_command(Keyword.fetch!(opts, :executable), Keyword.fetch!(opts, :args), run_opts),
         {:ok, cleanup_guard} <-
           start_cleanup_guard(
             self(),
             exec_pid,
             Keyword.get(run_opts, :on_timeout, fn -> :ok end)
           ) do
      timer =
        Process.send_after(self(), :execution_timeout, Keyword.fetch!(run_opts, :timeout_ms))

      {:ok,
       %{
         execution_id: execution_id,
         exec_pid: exec_pid,
         os_pid: os_pid,
         buffer: OutputBuffer.new(Keyword.get(run_opts, :max_output_bytes, 65_536)),
         timer: timer,
         waiters: [],
         result: nil,
         timed_out?: false,
         kill_grace_ms: Keyword.get(run_opts, :kill_grace_ms, @default_kill_grace_ms),
         on_timeout: Keyword.get(run_opts, :on_timeout, fn -> :ok end),
         cleanup_guard: cleanup_guard
       }}
    else
      {:error, reason} -> {:stop, {:execution_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:await, from, %{result: nil} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:await, _from, state), do: {:reply, state.result, state}

  def handle_call(:cancel, _from, %{result: nil} = state) do
    safe_callback(state.on_timeout)
    state = stop_group(state, false)
    {:reply, {:ok, :os_kill}, state}
  end

  def handle_call(:cancel, _from, state), do: {:reply, {:ok, :cooperative}, state}

  @impl true
  def handle_info({stream, os_pid, data}, %{os_pid: os_pid} = state)
      when stream in [:stdout, :stderr] do
    {:noreply, %{state | buffer: OutputBuffer.append(state.buffer, data)}}
  end

  def handle_info(
        {:DOWN, os_pid, :process, exec_pid, reason},
        %{os_pid: os_pid, exec_pid: exec_pid} = state
      ) do
    {:noreply, finish(state, exit_status(reason))}
  end

  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid, result: nil} = state) do
    {:noreply, finish(state, exit_status(reason))}
  end

  def handle_info(:execution_timeout, %{result: nil} = state) do
    safe_callback(state.on_timeout)
    {:noreply, state |> Map.put(:timed_out?, true) |> stop_group(true)}
  end

  def handle_info(:stop_if_finished, %{result: result} = state) when not is_nil(result),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{result: nil, exec_pid: exec_pid}) when is_pid(exec_pid) do
    _ = :exec.stop(exec_pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_command(executable, args, opts) do
    if File.regular?(executable) do
      command = [String.to_charlist(executable) | Enum.map(args, &String.to_charlist/1)]

      kill_seconds =
        max(1, ceil(Keyword.get(opts, :kill_grace_ms, @default_kill_grace_ms) / 1_000))

      exec_opts = [
        :monitor,
        {:stdout, self()},
        {:stderr, :stdout},
        {:group, 0},
        :kill_group,
        {:kill_timeout, kill_seconds},
        {:cd, String.to_charlist(Keyword.fetch!(opts, :cd))},
        {:env, normalize_env(Keyword.get(opts, :env, []))}
      ]

      :exec.run_link(command, exec_opts)
    else
      {:error, :executable_not_found}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp normalize_env(env) do
    Enum.map(env, fn
      {key, nil} -> {to_charlist(key), false}
      {key, value} -> {to_charlist(key), to_charlist(value)}
    end)
  end

  defp stop_group(state, timed_out?) do
    _ = :exec.stop_and_wait(state.exec_pid, state.kill_grace_ms + 1_000)
    finish(%{state | timed_out?: timed_out?}, nil)
  end

  defp finish(%{result: nil} = state, status) do
    if state.timer, do: Process.cancel_timer(state.timer)
    output = OutputBuffer.output(state.buffer)

    result =
      {:ok,
       %{
         exit_status: status,
         output: output,
         truncated?: state.buffer.truncated?,
         output_bytes: byte_size(output),
         timed_out?: state.timed_out?,
         execution_id: state.execution_id,
         os_pid: state.os_pid,
         containment: :process_group
       }}

    Enum.each(state.waiters, &GenServer.reply(&1, result))
    send(state.cleanup_guard, :disarm)
    Process.send_after(self(), :stop_if_finished, 10)
    %{state | result: result, waiters: []}
  end

  defp finish(state, _status), do: state

  defp exit_status(:normal), do: 0

  defp exit_status({:exit_status, raw}) do
    case :exec.status(raw) do
      {:status, status} -> status
      {:signal, _signal, _core?} -> nil
    end
  end

  defp exit_status(_reason), do: nil

  defp safe_callback(callback) do
    callback.()
  rescue
    _exception -> :ok
  end

  defp start_cleanup_guard(owner, exec_pid, cleanup) do
    Task.Supervisor.start_child(AllbertAssist.TaskSupervisor, fn ->
      monitor = Process.monitor(owner)

      receive do
        :disarm ->
          Process.demonitor(monitor, [:flush])

        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          safe_callback(cleanup)
          _ = :exec.stop(exec_pid)
      end
    end)
  end
end
