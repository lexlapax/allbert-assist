defmodule AllbertAssist.Channels.TUI.InputDriver do
  @moduledoc false

  use GenServer

  require Logger

  @type owner_event ::
          {:tui_input_line, pid(), String.t()}
          | {:tui_input_escape, pid()}
          | {:tui_input_quit, pid(), :ctrl_c | :ctrl_d}

  @doc "Start a raw terminal input driver that emits line and key events to owner."
  def start_link(owner, opts \\ []) when is_pid(owner) do
    GenServer.start_link(__MODULE__, {owner, opts})
  end

  @doc "Ask the driver to render a prompt and collect the next line."
  def prompt(driver, prompt) when is_pid(driver) do
    GenServer.cast(driver, {:prompt, prompt})
  end

  @doc "Put the driver in active-turn mode so Esc can cancel without a prompt."
  def active_turn(driver, turn_id) when is_pid(driver) do
    GenServer.cast(driver, {:active_turn, turn_id})
  end

  @doc "Run the interactive proof harness used by v0.57 M9.27."
  def run_proof(opts \\ []) do
    owner = self()
    output_fun = Keyword.get(opts, :output_fun, &default_output/1)
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    with {:ok, driver} <- start_link(owner, Keyword.put(opts, :output_fun, output_fun)) do
      prompt(driver, "allbert:proof> ")

      receive do
        {:tui_input_escape, ^driver} ->
          output_fun.("PROOF:ESC\n")
          GenServer.stop(driver)
          :ok

        {:tui_input_line, ^driver, line} ->
          output_fun.("PROOF:LINE #{line}\n")
          GenServer.stop(driver)
          :ok

        {:tui_input_quit, ^driver, reason} ->
          output_fun.("PROOF:QUIT #{reason}\n")
          GenServer.stop(driver)
          :ok
      after
        timeout_ms ->
          output_fun.("PROOF:TIMEOUT\n")
          GenServer.stop(driver)
          {:error, :timeout}
      end
    end
  end

  @impl true
  def init({owner, opts}) do
    Process.flag(:trap_exit, true)

    callbacks = callbacks(opts)

    case callbacks.enable_raw.() do
      :ok ->
        case callbacks.start_reader.(self(), callbacks.read_char) do
          {:ok, reader_pid} when is_pid(reader_pid) ->
            {:ok,
             %{
               owner: owner,
               callbacks: callbacks,
               reader_pid: reader_pid,
               reader_ref: Process.monitor(reader_pid),
               mode: :idle,
               buffer: "",
               turn_id: nil
             }}

          {:error, reason} ->
            callbacks.disable_raw.()
            {:stop, {:input_reader_unavailable, reason}}

          other ->
            callbacks.disable_raw.()
            {:stop, {:input_reader_unavailable, other}}
        end

      {:error, reason} ->
        {:stop, {:raw_terminal_unavailable, reason}}

      other ->
        {:stop, {:raw_terminal_unavailable, other}}
    end
  end

  @impl true
  def handle_cast({:prompt, prompt}, state) do
    state.callbacks.output_fun.(prompt)
    {:noreply, %{state | mode: :prompt, buffer: "", turn_id: nil}}
  end

  def handle_cast({:active_turn, turn_id}, state) do
    {:noreply, %{state | mode: :active_turn, buffer: "", turn_id: turn_id}}
  end

  @impl true
  def handle_info({:tui_input_driver_char, reader_pid, char}, %{reader_pid: reader_pid} = state) do
    {:noreply, handle_char(to_binary(char), state)}
  end

  def handle_info({:tui_input_driver_reader_error, reader_pid, reason}, state)
      when reader_pid == state.reader_pid do
    Logger.debug("tui input reader stopped: #{inspect(reason)}")
    {:stop, {:input_reader_stopped, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state)
      when ref == state.reader_ref and pid == state.reader_pid do
    {:stop, {:input_reader_down, reason}, %{state | reader_ref: nil, reader_pid: nil}}
  end

  def handle_info({:EXIT, pid, reason}, state) when pid == state.reader_pid do
    {:stop, {:input_reader_exit, reason}, %{state | reader_pid: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_reader(state)
    state.callbacks.disable_raw.()
    :ok
  end

  defp handle_char(char, %{mode: mode} = state) when mode in [:prompt, :active_turn] do
    cond do
      escape?(char) ->
        send(state.owner, {:tui_input_escape, self()})
        %{state | buffer: ""}

      enter?(char) ->
        state.callbacks.output_fun.("\n")
        line = state.buffer
        send(state.owner, {:tui_input_line, self(), line})
        %{state | mode: next_mode_after_line(state), buffer: ""}

      backspace?(char) ->
        erase_last_char(state)

      ctrl_c?(char) ->
        state.callbacks.output_fun.("\n")
        send(state.owner, {:tui_input_quit, self(), :ctrl_c})
        %{state | mode: :idle, buffer: ""}

      ctrl_d?(char) and state.buffer == "" ->
        state.callbacks.output_fun.("\n")
        send(state.owner, {:tui_input_quit, self(), :ctrl_d})
        %{state | mode: :idle, buffer: ""}

      printable?(char) ->
        state.callbacks.output_fun.(char)
        %{state | buffer: state.buffer <> char}

      true ->
        state
    end
  end

  defp handle_char(char, state) do
    if escape?(char) do
      send(state.owner, {:tui_input_escape, self()})
    end

    state
  end

  defp next_mode_after_line(%{mode: :active_turn}), do: :active_turn
  defp next_mode_after_line(_state), do: :idle

  defp erase_last_char(%{buffer: ""} = state), do: state

  defp erase_last_char(state) do
    state.callbacks.output_fun.("\b \b")
    %{state | buffer: drop_last_grapheme(state.buffer)}
  end

  defp drop_last_grapheme(text) do
    text
    |> String.graphemes()
    |> Enum.drop(-1)
    |> Enum.join()
  end

  defp escape?("\e"), do: true
  defp escape?(_char), do: false

  defp enter?("\n"), do: true
  defp enter?("\r"), do: true
  defp enter?(_char), do: false

  defp backspace?("\b"), do: true
  defp backspace?(<<127>>), do: true
  defp backspace?(_char), do: false

  defp ctrl_c?(<<3>>), do: true
  defp ctrl_c?(_char), do: false

  defp ctrl_d?(<<4>>), do: true
  defp ctrl_d?(_char), do: false

  defp printable?(<<codepoint::utf8>>) when codepoint >= 32 and codepoint != 127, do: true
  defp printable?(_char), do: false

  defp stop_reader(%{reader_pid: pid, reader_ref: ref}) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])

    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  defp callbacks(opts) do
    %{
      enable_raw: Keyword.get(opts, :enable_raw, &enable_raw_terminal/0),
      disable_raw: Keyword.get(opts, :disable_raw, &disable_raw_terminal/0),
      start_reader: Keyword.get(opts, :start_reader, &start_reader/2),
      read_char: Keyword.get(opts, :read_char, &read_char/0),
      output_fun: Keyword.get(opts, :output_fun, &default_output/1)
    }
  end

  defp start_reader(driver, read_fun) do
    pid =
      spawn_link(fn ->
        reader_loop(driver, read_fun)
      end)

    {:ok, pid}
  end

  defp reader_loop(driver, read_fun) do
    case read_fun.() do
      {:ok, char} ->
        send(driver, {:tui_input_driver_char, self(), char})
        reader_loop(driver, read_fun)

      :eof ->
        send(driver, {:tui_input_driver_reader_error, self(), :eof})

      {:error, reason} ->
        send(driver, {:tui_input_driver_reader_error, self(), reason})
    end
  end

  defp enable_raw_terminal do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok -> :ok
      other -> {:error, other}
    end
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp disable_raw_terminal do
    _result = :shell.start_interactive({:noshell, :cooked})
    :ok
  rescue
    error ->
      Logger.debug("tui input driver raw restore failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.debug("tui input driver raw restore failed: #{inspect({kind, reason})}")
      :ok
  end

  defp read_char do
    case :io.get_chars(:standard_io, "", 1) do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      char when is_binary(char) -> {:ok, char}
      char when is_list(char) -> {:ok, List.to_string(char)}
      other -> {:error, {:unexpected_input, other}}
    end
  end

  defp to_binary(value) when is_binary(value), do: value
  defp to_binary(value) when is_list(value), do: List.to_string(value)
  defp to_binary(value), do: to_string(value)

  defp default_output(chardata) do
    IO.write(chardata)
  end
end
