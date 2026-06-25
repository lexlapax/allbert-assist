defmodule AllbertAssist.Channels.TUI.EscapeMonitor do
  @moduledoc false

  require Logger

  @poll_time_ds "1"
  @stty_raw_args ["-echo", "-icanon", "min", "0", "time", @poll_time_ds]
  @tty_prefixes [[], ["-f", "/dev/tty"], ["-F", "/dev/tty"]]

  def start(owner, event_ref) when is_pid(owner) and is_reference(event_ref) do
    {:ok,
     spawn(fn ->
       monitor_owner = Process.monitor(owner)
       run(owner, event_ref, monitor_owner)
     end)}
  end

  defp run(owner, event_ref, monitor_owner) do
    with {:ok, snapshot} <- stty_snapshot(),
         :ok <- stty_apply(@stty_raw_args) do
      try do
        loop(owner, event_ref, monitor_owner)
      after
        restore(snapshot)
      end
    else
      {:error, reason} ->
        Logger.debug("tui escape monitor unavailable: #{inspect(reason)}")
        :ok
    end
  end

  defp loop(owner, event_ref, monitor_owner) do
    receive do
      {:stop_escape_monitor, ^event_ref} ->
        :ok

      {:DOWN, ^monitor_owner, :process, ^owner, _reason} ->
        :ok
    after
      0 ->
        case read_char() do
          "\e" ->
            if standalone_escape?() do
              send(owner, {:coding_tui_escape, event_ref})
              :ok
            else
              loop(owner, event_ref, monitor_owner)
            end

          _other ->
            loop(owner, event_ref, monitor_owner)
        end
    end
  end

  defp standalone_escape? do
    case read_char() do
      "" -> true
      nil -> true
      :eof -> true
      {:error, _reason} -> true
      _sequence_char -> false
    end
  end

  defp read_char do
    IO.getn(:stdio, "", 1)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp stty_snapshot do
    run_stty(["-g"], fn output, prefix ->
      {:ok, %{prefix: prefix, snapshot: String.trim(output)}}
    end)
  end

  defp stty_apply(args) do
    run_stty(args, fn _output, _prefix -> :ok end)
  end

  defp run_stty(args, on_success) do
    Enum.reduce_while(@tty_prefixes, {:error, :stty_unavailable}, fn prefix, _last_error ->
      case run_stty_once(prefix ++ args) do
        {:ok, output} -> {:halt, on_success.(output, prefix)}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp run_stty_once(args) do
    case System.cmd("stty", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, %{status: status, output: String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp restore(%{prefix: prefix, snapshot: snapshot})
       when is_binary(snapshot) and snapshot != "" do
    _result = System.cmd("stty", prefix ++ [snapshot], stderr_to_stdout: true)
    :ok
  rescue
    error ->
      Logger.debug("tui escape monitor restore failed: #{Exception.message(error)}")
      :ok
  end
end
