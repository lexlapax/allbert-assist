defmodule AllbertAssist.Channels.TUI.EscapeMonitor do
  @moduledoc false

  require Logger

  @helper_ready "READY"
  @helper_escape "ESC"
  @helper_timeout_ms 1_000

  def start(owner, event_ref) when is_pid(owner) and is_reference(event_ref) do
    start(owner, event_ref, [])
  end

  def start(owner, event_ref, opts) when is_pid(owner) and is_reference(event_ref) do
    starter = self()
    startup_ref = make_ref()
    callbacks = callbacks(opts)

    pid =
      spawn(fn ->
        monitor_owner = Process.monitor(owner)
        run(owner, event_ref, monitor_owner, starter, startup_ref, callbacks)
      end)

    receive do
      {^startup_ref, ^pid, :ready} ->
        {:ok, pid}

      {^startup_ref, ^pid, {:error, reason}} ->
        {:error, reason}
    after
      @helper_timeout_ms ->
        send(pid, {:stop_escape_monitor, event_ref})
        {:error, :escape_monitor_start_timeout}
    end
  end

  defp run(owner, event_ref, monitor_owner, starter, startup_ref, callbacks) do
    with {:ok, helper} <- callbacks.start_helper.() do
      loop(%{
        owner: owner,
        event_ref: event_ref,
        monitor_owner: monitor_owner,
        starter: starter,
        startup_ref: startup_ref,
        callbacks: callbacks,
        helper: helper,
        ready?: false,
        helper_output: []
      })
    else
      {:error, reason} ->
        Logger.debug("tui escape monitor unavailable: #{inspect(reason)}")
        send(starter, {startup_ref, self(), {:error, reason}})
    end
  end

  defp loop(state) do
    receive do
      {:stop_escape_monitor, event_ref} when event_ref == state.event_ref ->
        stop_helper(state)

      {:DOWN, monitor_owner, :process, owner, _reason}
      when monitor_owner == state.monitor_owner and owner == state.owner ->
        stop_helper(state)

      {port, {:data, {_line, data}}} when port == state.helper.port ->
        handle_helper_line(data, state)

      {port, {:data, data}} when port == state.helper.port ->
        handle_helper_line(data, state)

      {port, {:exit_status, status}} when port == state.helper.port ->
        helper_exited(status, state)
    end
  end

  defp handle_helper_line(data, state) when is_binary(data) do
    data
    |> String.trim()
    |> case do
      @helper_ready ->
        send(state.starter, {state.startup_ref, self(), :ready})
        loop(%{state | ready?: true})

      @helper_escape ->
        send(state.owner, {:coding_tui_escape, state.event_ref})
        stop_helper(state)

      "" ->
        loop(state)

      line ->
        loop(%{state | helper_output: [line | state.helper_output]})
    end
  end

  defp handle_helper_line(_data, state), do: loop(state)

  defp helper_exited(0, %{ready?: true} = state), do: state

  defp helper_exited(status, %{ready?: false} = state) do
    reason = {:escape_monitor_helper_exit, status, Enum.reverse(state.helper_output)}
    Logger.debug("tui escape monitor helper exited before ready: #{inspect(reason)}")
    send(state.starter, {state.startup_ref, self(), {:error, reason}})
    state
  end

  defp helper_exited(_status, state), do: state

  defp stop_helper(state) do
    state.callbacks.stop_helper.(state.helper)
    :ok
  end

  defp callbacks(opts) do
    %{
      start_helper: Keyword.get(opts, :start_helper, &start_shell_helper/0),
      stop_helper: Keyword.get(opts, :stop_helper, &stop_shell_helper/1)
    }
  end

  defp start_shell_helper do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["-c", helper_script()]},
        {:line, 512}
      ])

    {:ok, %{port: port, os_pid: os_pid(port)}}
  rescue
    error -> {:error, error}
  end

  defp stop_shell_helper(%{port: port, os_pid: os_pid}) do
    if is_integer(os_pid) do
      _result = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    Port.close(port)
    :ok
  rescue
    error ->
      Logger.debug("tui escape monitor helper stop failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("tui escape monitor helper stop failed: #{inspect(reason)}")
      :ok
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _other -> nil
    end
  end

  defp helper_script do
    """
    old=$(stty -g < /dev/tty) || exit 2
    cleanup() { stty "$old" < /dev/tty >/dev/null 2>&1 || true; }
    trap cleanup EXIT HUP INT TERM
    stty -echo -icanon min 0 time 1 < /dev/tty || exit 3
    printf '#{@helper_ready}\\n'
    while :; do
      byte=$(dd bs=1 count=1 2>/dev/null < /dev/tty | od -An -tu1 | tr -d '[:space:]')
      if [ "$byte" = "27" ]; then
        printf '#{@helper_escape}\\n'
        exit 0
      fi
    done
    """
  end
end
