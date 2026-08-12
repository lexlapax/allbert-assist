defmodule AllbertTUI.InputDriver do
  @moduledoc false

  use GenServer

  require Logger

  @maximum_buffer_bytes 32_000

  @type owner_event ::
          {:tui_input_line, pid(), String.t()}
          | {:tui_input_escape, pid()}
          | {:tui_input_quit, pid(), :ctrl_c | :ctrl_d}

  @doc "Start a raw terminal input driver that emits line and key events to owner."
  def start_link(owner, opts \\ []) when is_pid(owner) do
    GenServer.start_link(__MODULE__, {owner, opts})
  end

  @doc """
  Start an UNLINKED input driver (v1.0.1 M4.1B). The adapter monitors the driver
  and owns the line-mode fallback on `:DOWN`; a link would kill the adapter when
  raw-terminal init fails (e.g. `:enotsup` with no TTY), turning a degradable
  condition into a whole-app boot abort.
  """
  def start(owner, opts \\ []) when is_pid(owner) do
    GenServer.start(__MODULE__, {owner, opts})
  end

  @doc "Ask the driver to render a prompt and collect the next line."
  def prompt(driver, prompt) when is_pid(driver) do
    GenServer.cast(driver, {:prompt, prompt})
  end

  @doc "Write one attended output line and redraw any active prompt buffer atomically."
  def write(driver, line) when is_pid(driver) do
    GenServer.call(driver, {:write, line}, 5_000)
  end

  @doc "Replace the one bounded transient live region without redrawing the viewport."
  def update_live(driver, columns, lines)
      when is_pid(driver) and is_integer(columns) and is_list(lines) do
    GenServer.call(driver, {:update_live, columns, lines}, 5_000)
  end

  @doc "Put the driver in active-turn mode so Esc can cancel without a prompt."
  def active_turn(driver, turn_id) when is_pid(driver) do
    GenServer.cast(driver, {:active_turn, turn_id})
  end

  @doc "Pause normal terminal demand while retaining at most one control/input character."
  @spec pause(pid()) :: :ok
  def pause(driver) when is_pid(driver), do: GenServer.call(driver, :pause)

  @doc "Resume terminal demand after transport pressure clears."
  @spec resume(pid()) :: :ok
  def resume(driver) when is_pid(driver), do: GenServer.call(driver, :resume)

  @doc "Run the interactive proof harness used by v0.57 M9.27."
  def run_proof(opts \\ []) do
    owner = self()
    output_fun = Keyword.get(opts, :output_fun, &default_output/1)
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    with {:ok, driver} <- start_link(owner, Keyword.put(opts, :output_fun, output_fun)) do
      prompt(driver, "allbert:proof> ")

      receive do
        {:tui_input_escape, ^driver} ->
          proof_line(output_fun, "PROOF:ESC")
          GenServer.stop(driver)
          :ok

        {:tui_input_line, ^driver, line} ->
          proof_line(output_fun, "PROOF:LINE #{line}")
          GenServer.stop(driver)
          :ok

        {:tui_input_quit, ^driver, reason} ->
          proof_line(output_fun, "PROOF:QUIT #{reason}")
          GenServer.stop(driver)
          :ok
      after
        timeout_ms ->
          proof_line(output_fun, "PROOF:TIMEOUT")
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
               prompt: "",
               buffer: "",
               turn_id: nil,
               max_buffer_bytes: max_buffer_bytes(opts),
               live_region?: Keyword.get(opts, :live_region?, false) == true,
               terminal_columns: terminal_columns(opts),
               live_lines: [],
               rendered_region_rows: 0,
               paused?: false,
               read_pending?: false,
               deferred_char: nil,
               single_submission?: Keyword.get(opts, :single_submission?, false) == true
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
    prompt = IO.iodata_to_binary(prompt)

    state =
      if state.live_region? do
        state
        |> clear_live_region()
        |> Map.merge(%{mode: :prompt, prompt: prompt, turn_id: nil})
        |> render_live_region()
      else
        state.callbacks.output_fun.(prompt)

        if state.buffer != "" do
          state.callbacks.output_fun.(state.buffer)
        end

        %{state | mode: :prompt, prompt: prompt, turn_id: nil}
      end

    {:noreply, demand_reader(state)}
  end

  def handle_cast({:active_turn, turn_id}, state) do
    state =
      if state.live_region? do
        state
        |> clear_live_region()
        |> Map.merge(%{mode: :active_turn, buffer: "", turn_id: turn_id})
        |> render_live_region()
      else
        %{state | mode: :active_turn, buffer: "", turn_id: turn_id}
      end

    {:noreply, demand_reader(state)}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    state = state |> Map.put(:paused?, true) |> demand_one_paused_char()
    {:reply, :ok, state}
  end

  def handle_call(:resume, _from, %{paused?: true} = state) do
    state = %{state | paused?: false}

    state =
      case state.deferred_char do
        nil ->
          state

        char ->
          handle_char(char, %{state | deferred_char: nil})
      end

    {:reply, :ok, demand_reader(state)}
  end

  def handle_call(:resume, _from, state), do: {:reply, :ok, demand_reader(state)}

  @impl true
  def handle_call({:write, line}, _from, state) do
    if state.live_region? do
      case write_live_static(state, line) do
        {:ok, state} -> {:reply, :ok, state}
        {:error, reason, state} -> {:reply, {:error, reason}, state}
      end
    else
      output = attended_output(line, state)
      {:reply, safe_output(state.callbacks.output_fun, output), state}
    end
  end

  def handle_call({:update_live, columns, lines}, _from, state) do
    if state.live_region? do
      case replace_live_region(state, columns, lines) do
        {:ok, state} -> {:reply, :ok, state}
        {:error, reason, state} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :live_region_disabled}, state}
    end
  end

  @impl true
  def handle_info({:tui_input_driver_char, reader_pid, char}, %{reader_pid: reader_pid} = state) do
    state = %{state | read_pending?: false}
    char = to_binary(char)

    state =
      if state.paused? do
        defer_char(state, char)
      else
        handle_char(char, state)
      end

    {:noreply, demand_reader(state)}
  end

  def handle_info({:tui_input_driver_reader_error, reader_pid, :eof}, state)
      when reader_pid == state.reader_pid do
    if is_reference(state.reader_ref), do: Process.demonitor(state.reader_ref, [:flush])

    state = finish_input_quit(state, :ctrl_d)

    {:noreply, %{state | reader_pid: nil, reader_ref: nil, read_pending?: false, paused?: true}}
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

  defp handle_char(char, %{mode: mode} = state)
       when mode in [:prompt, :awaiting_prompt, :active_turn] do
    cond do
      escape?(char) ->
        send(state.owner, {:tui_input_escape, self()})
        clear_input_buffer(state)

      enter?(char) ->
        finish_input_line(state)

      backspace?(char) ->
        erase_last_char(state)

      ctrl_c?(char) ->
        finish_input_quit(state, :ctrl_c)

      ctrl_d?(char) and state.buffer == "" ->
        finish_input_quit(state, :ctrl_d)

      printable?(char) ->
        append_printable(state, char)

      true ->
        state
    end
  end

  defp handle_char(char, state) do
    cond do
      escape?(char) ->
        send(state.owner, {:tui_input_escape, self()})
        state

      ctrl_c?(char) ->
        finish_input_quit(state, :ctrl_c)

      ctrl_d?(char) ->
        finish_input_quit(state, :ctrl_d)

      true ->
        state
    end
  end

  defp clear_input_buffer(%{live_region?: true} = state) do
    state
    |> clear_live_region()
    |> Map.put(:buffer, "")
    |> render_live_region()
  end

  defp clear_input_buffer(state), do: %{state | buffer: ""}

  defp finish_input_line(%{live_region?: true} = state) do
    line = state.buffer

    state = clear_live_region(state)
    state.callbacks.output_fun.([state.prompt, line, "\r\n"])
    send(state.owner, {:tui_input_line, self(), line})

    state
    |> Map.merge(%{mode: next_mode_after_line(state), buffer: ""})
    |> render_live_region()
  end

  defp finish_input_line(state) do
    state.callbacks.output_fun.("\r\n")
    line = state.buffer
    send(state.owner, {:tui_input_line, self(), line})
    %{state | mode: next_mode_after_line(state), buffer: ""}
  end

  defp finish_input_quit(%{live_region?: true} = state, reason) do
    state = clear_live_region(state)
    state.callbacks.output_fun.("\r\n")
    send(state.owner, {:tui_input_quit, self(), reason})
    %{state | mode: :idle, buffer: "", live_lines: [], rendered_region_rows: 0}
  end

  defp finish_input_quit(state, reason) do
    state.callbacks.output_fun.("\r\n")
    send(state.owner, {:tui_input_quit, self(), reason})
    %{state | mode: :idle, buffer: ""}
  end

  defp next_mode_after_line(%{mode: :active_turn}), do: :active_turn
  defp next_mode_after_line(_state), do: :awaiting_prompt

  defp erase_last_char(%{buffer: ""} = state), do: state

  defp erase_last_char(%{live_region?: true} = state) do
    state
    |> clear_live_region()
    |> Map.update!(:buffer, &drop_last_grapheme/1)
    |> render_live_region()
  end

  defp erase_last_char(state) do
    if state.mode != :awaiting_prompt do
      state.callbacks.output_fun.("\b \b")
    end

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

  defp printable?(<<codepoint::utf8>>)
       when codepoint >= 32 and codepoint not in 127..159,
       do: true

  defp printable?(_char), do: false

  defp append_printable(state, char) do
    if byte_size(state.buffer) + byte_size(char) <= state.max_buffer_bytes do
      if state.mode != :awaiting_prompt do
        state.callbacks.output_fun.(char)
      end

      state = %{state | buffer: state.buffer <> char}

      if state.live_region? and state.mode != :awaiting_prompt do
        %{state | rendered_region_rows: live_region_rows(state)}
      else
        state
      end
    else
      state.callbacks.output_fun.("\a")
      state
    end
  end

  defp stop_reader(%{reader_pid: pid, reader_ref: ref}) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])

    if is_pid(pid) and Process.alive?(pid) do
      send(pid, {:tui_input_driver_stop, self()})
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

  defp clear_live_region(%{live_region?: true, rendered_region_rows: rows} = state)
       when rows > 0 do
    case clear_live_region_checked(state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp clear_live_region(state), do: state

  defp clear_live_region_checked(%{live_region?: true, rendered_region_rows: rows} = state)
       when rows > 0 do
    clear_previous_rows =
      List.duplicate([IO.ANSI.cursor_up(1), "\r", IO.ANSI.clear_line()], rows - 1)

    case safe_output(state.callbacks.output_fun, [
           "\r",
           IO.ANSI.clear_line(),
           clear_previous_rows
         ]) do
      :ok -> {:ok, %{state | rendered_region_rows: 0}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp clear_live_region_checked(state), do: {:ok, state}

  defp render_live_region(%{live_region?: true} = state) do
    case render_live_region_checked(state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp render_live_region(state), do: state

  defp render_live_region_checked(%{live_region?: true} = state) do
    input_line = live_input_line(state)

    lines =
      if is_nil(input_line),
        do: state.live_lines,
        else: state.live_lines ++ [input_line]

    result =
      if lines == [],
        do: :ok,
        else: safe_output(state.callbacks.output_fun, Enum.intersperse(lines, "\r\n"))

    case result do
      :ok -> {:ok, %{state | rendered_region_rows: live_region_rows(state)}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp render_live_region_checked(state), do: {:ok, state}

  defp write_live_static(state, line) do
    with {:ok, state} <- clear_live_region_checked(state),
         {:ok, state} <- output_checked(state, normalize_line(line)),
         {:ok, state} <- render_live_region_checked(state) do
      {:ok, state}
    end
  end

  defp replace_live_region(state, columns, lines) do
    with {:ok, state} <- clear_live_region_checked(state) do
      state = %{
        state
        | terminal_columns: clamp_columns(columns),
          live_lines: Enum.map(lines, &IO.iodata_to_binary/1)
      }

      render_live_region_checked(state)
    end
  end

  defp output_checked(state, output) do
    case safe_output(state.callbacks.output_fun, output) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp live_input_line(%{mode: :prompt} = state), do: state.prompt <> state.buffer
  defp live_input_line(%{mode: :active_turn} = state), do: state.buffer
  defp live_input_line(_state), do: nil

  defp live_region_rows(state) do
    input_line = live_input_line(state)

    lines =
      if is_nil(input_line),
        do: state.live_lines,
        else: state.live_lines ++ [input_line]

    Enum.reduce(lines, 0, fn line, rows ->
      rows + display_rows(line, state.terminal_columns)
    end)
  end

  defp display_rows(line, columns) do
    length = Owl.Data.length(line)
    max(1, div(max(length - 1, 0), columns) + 1)
  end

  defp terminal_columns(opts),
    do: opts |> Keyword.get(:terminal_columns, 80) |> clamp_columns()

  defp clamp_columns(columns) when is_integer(columns), do: min(max(columns, 1), 500)
  defp clamp_columns(_invalid), do: 80

  defp max_buffer_bytes(opts) do
    case Keyword.get(opts, :max_buffer_bytes, @maximum_buffer_bytes) do
      bytes when is_integer(bytes) and bytes in 1..@maximum_buffer_bytes -> bytes
      _invalid -> @maximum_buffer_bytes
    end
  end

  defp start_reader(driver, read_fun) do
    pid =
      spawn_link(fn ->
        reader_loop(driver, read_fun)
      end)

    {:ok, pid}
  end

  defp reader_loop(driver, read_fun) do
    receive do
      {:tui_input_driver_read, ^driver} ->
        case read_fun.() do
          {:ok, char} ->
            send(driver, {:tui_input_driver_char, self(), char})
            reader_loop(driver, read_fun)

          :eof ->
            send(driver, {:tui_input_driver_reader_error, self(), :eof})

          {:error, reason} ->
            send(driver, {:tui_input_driver_reader_error, self(), reason})
        end

      {:tui_input_driver_stop, ^driver} ->
        :ok
    end
  end

  defp demand_reader(%{paused?: true} = state), do: state
  defp demand_reader(%{read_pending?: true} = state), do: state
  defp demand_reader(%{mode: :idle} = state), do: state

  defp demand_reader(%{single_submission?: true, mode: :awaiting_prompt} = state),
    do: state

  defp demand_reader(%{reader_pid: reader_pid} = state) when is_pid(reader_pid) do
    send(reader_pid, {:tui_input_driver_read, self()})
    %{state | read_pending?: true}
  end

  defp demand_reader(state), do: state

  defp demand_one_paused_char(
         %{
           deferred_char: nil,
           read_pending?: false,
           reader_pid: reader_pid
         } = state
       )
       when is_pid(reader_pid) do
    send(reader_pid, {:tui_input_driver_read, self()})
    %{state | read_pending?: true}
  end

  defp demand_one_paused_char(state), do: state

  # The production reader is demand-driven, so at most the character already
  # inside `:io.get_chars/3` can arrive after pause. Keep it for resume rather
  # than treating pressure as permission to lose operator input.
  defp defer_char(%{deferred_char: nil} = state, char), do: %{state | deferred_char: char}

  defp defer_char(state, _char) do
    state.callbacks.output_fun.("\a")
    state
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
    end
  end

  defp to_binary(value) when is_binary(value), do: value
  defp to_binary(value) when is_list(value), do: List.to_string(value)
  defp to_binary(value), do: to_string(value)

  defp default_output(chardata) do
    IO.write(chardata)
  end

  defp attended_output(line, state) do
    line = normalize_line(line)

    case state.mode do
      :prompt -> ["\r\e[2K", line, state.prompt, state.buffer]
      :active_turn -> ["\r\e[2K", line, state.buffer]
      _other -> line
    end
  end

  defp normalize_line(chardata) do
    text =
      chardata
      |> IO.iodata_to_binary()
      |> String.replace("\r\n", "\n")
      |> String.replace("\n", "\r\n")

    if String.ends_with?(text, "\r\n"), do: text, else: text <> "\r\n"
  end

  defp safe_output(output_fun, output) do
    case output_fun.(output) do
      {:error, _reason} = error -> error
      _delivered -> :ok
    end
  rescue
    error -> {:error, {:output_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:output_exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp proof_line(output_fun, text) do
    output_fun.([text, "\r\n"])
  end
end
