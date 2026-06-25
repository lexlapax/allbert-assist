defmodule AllbertAssist.Channels.TUI.EscapeMonitor do
  @moduledoc false

  require Logger

  @tty_path "/dev/tty"
  @poll_time_ds "1"
  @stty_raw_args ["-echo", "-icanon", "min", "0", "time", @poll_time_ds]

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
        with {:ok, tty} <- File.open(@tty_path, [:read, :binary]) do
          try do
            loop(owner, event_ref, monitor_owner, tty)
          after
            File.close(tty)
          end
        else
          {:error, reason} ->
            Logger.debug("tui escape monitor could not open #{@tty_path}: #{inspect(reason)}")
            :ok
        end
      after
        restore(snapshot)
      end
    else
      {:error, reason} ->
        Logger.debug("tui escape monitor unavailable: #{inspect(reason)}")
        :ok
    end
  end

  defp loop(owner, event_ref, monitor_owner, tty) do
    receive do
      {:stop_escape_monitor, ^event_ref} ->
        :ok

      {:DOWN, ^monitor_owner, :process, ^owner, _reason} ->
        :ok
    after
      0 ->
        case read_char(tty) do
          "\e" ->
            if standalone_escape?(tty) do
              send(owner, {:coding_tui_escape, event_ref})
              :ok
            else
              loop(owner, event_ref, monitor_owner, tty)
            end

          _other ->
            loop(owner, event_ref, monitor_owner, tty)
        end
    end
  end

  defp standalone_escape?(tty) do
    case read_char(tty) do
      "" -> true
      nil -> true
      :eof -> true
      {:error, _reason} -> true
      _sequence_char -> false
    end
  end

  defp read_char(tty) do
    IO.binread(tty, 1)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp stty_snapshot do
    run_stty(["-g"], fn output ->
      {:ok, String.trim(output)}
    end)
  end

  defp stty_apply(args) do
    run_stty(args, fn _output -> :ok end)
  end

  defp run_stty(args, on_success) do
    command =
      args
      |> Enum.map(&shell_quote/1)
      |> Enum.join(" ")

    case run_stty_shell("stty #{command} < #{@tty_path}") do
      {:ok, output} -> on_success.(output)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_stty_shell(command) do
    case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, %{status: status, output: String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp restore(snapshot) when is_binary(snapshot) and snapshot != "" do
    _result =
      System.cmd("sh", ["-c", "stty \"$1\" < #{@tty_path}", "sh", snapshot],
        stderr_to_stdout: true
      )

    :ok
  rescue
    error ->
      Logger.debug("tui escape monitor restore failed: #{Exception.message(error)}")
      :ok
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
