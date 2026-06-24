defmodule AllbertAssist.Channels.TUI.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.ConfirmationCallback
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.InboundTrust
  alias AllbertAssist.Channels.TUI.LiveRegion
  alias AllbertAssist.Channels.TUI.Renderer
  alias AllbertAssist.Channels.TUI.SlashCommands
  alias AllbertAssist.Coding.Config, as: CodingConfig
  alias AllbertAssist.Coding.Session, as: CodingSession
  alias AllbertAssist.Coding.TurnSupervisor, as: CodingTurnSupervisor
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.Redactor

  @provider "terminal"
  @channel "tui"
  @quit_commands MapSet.new(["/quit", "/exit"])

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: Keyword.get(opts, :restart, :permanent),
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  def submit(server \\ __MODULE__, text, opts \\ []) when is_binary(text) do
    GenServer.call(server, {:submit, text, opts}, Keyword.get(opts, :timeout_ms, 120_000))
  end

  def cancel_current_turn(server \\ __MODULE__, reason \\ :operator_escape) do
    GenServer.call(server, {:cancel_current_turn, reason}, 120_000)
  end

  def run_supervised_forever(supervisor \\ AllbertAssist.Channels.Supervisor) do
    with {:ok, pid} <- supervised_pid(supervisor) do
      wait_for_supervised_child(supervisor, pid)
    end
  end

  @impl true
  def init(opts) do
    state =
      opts
      |> load_state()
      |> emit_banner()

    if state.enabled? and state.auto_input? do
      Process.send_after(self(), :read_input, 0)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, text, opts}, _from, state) do
    {reply, state} = handle_text_submission(text, opts, state)
    {:reply, reply, state}
  end

  def handle_call({:cancel_current_turn, reason}, _from, state) do
    {reply, state} = cancel_current_turn_state(reason, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:read_input, state) do
    state = update_live_status(state, :ready)

    case state.input_fun.(Renderer.prompt(state.profile)) |> normalize_input() do
      :escape ->
        {reply, state} = cancel_current_turn_state(:operator_escape, state)
        maybe_emit_cancel_feedback(reply, state)
        Process.send_after(self(), :read_input, 0)
        {:noreply, state}

      command when is_binary(command) ->
        if MapSet.member?(@quit_commands, command) do
          {:stop, :normal, state}
        else
          state = update_live_status(state, :processing)
          {_reply, state} = handle_text_submission(command, [async?: state.coding_mode?], state)
          Process.send_after(self(), :read_input, 0)
          {:noreply, state}
        end

      _other ->
        Process.send_after(self(), :read_input, 0)
        {:noreply, state}
    end
  end

  def handle_info({:coding_tui_turn_finished, turn_id, _reply}, state) do
    state =
      case state.current_turn do
        %{turn_id: ^turn_id} ->
          state
          |> Map.put(:current_turn, nil)
          |> start_queued_correction()

        _other ->
          state
      end

    if state.auto_input? do
      Process.send_after(self(), :read_input, 0)
    end

    {:noreply, state}
  end

  def handle_info({:coding_stream_event, turn_id, event}, state) do
    state =
      case state.current_turn do
        %{turn_id: ^turn_id, live_region: live_region} when is_map(live_region) ->
          apply_live_stream_event(state, event)

        _other ->
          state
      end

    {:noreply, state}
  end

  defp load_state(opts) do
    settings =
      case Channels.channel_settings(@channel) do
        {:ok, settings} -> settings
        {:error, _reason} -> %{}
      end

    profile =
      opts
      |> Keyword.get(:profile, Map.get(settings, "profile", "default"))
      |> normalize_profile()

    enabled? = Keyword.get(opts, :enabled?, Map.get(settings, "enabled", false))

    %{
      enabled?: enabled?,
      auto_input?: Keyword.get(opts, :auto_input?, false),
      emit_banner?: Keyword.get(opts, :emit_banner?, Keyword.get(opts, :auto_input?, false)),
      settings: settings,
      profile: profile,
      live_screen?: Keyword.get(opts, :live_screen?, false),
      live_screen_server: Keyword.get(opts, :live_screen_server, Owl.LiveScreen),
      live_status_active?: false,
      input_fun: Keyword.get(opts, :input_fun, &default_input/1),
      output_fun: Keyword.get(opts, :output_fun),
      max_text_bytes: Map.get(settings, "max_text_bytes", 12_000),
      coding_mode?: Keyword.get(opts, :coding_mode?, false),
      pi_session: Keyword.get(opts, :pi_session),
      current_turn: nil,
      queued_correction: nil
    }
  end

  defp normalize_profile(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "default"
      profile -> profile
    end
  end

  defp add_live_block(server, profile) do
    Owl.LiveScreen.add_block(server, :allbert_tui_status,
      state: Renderer.status(profile, :starting),
      render: &Function.identity/1
    )
  end

  defp emit_banner(%{enabled?: false} = state), do: state
  defp emit_banner(%{emit_banner?: false} = state), do: state

  defp emit_banner(state) do
    state.profile
    |> Renderer.banner()
    |> Enum.each(&emit_output(&1, state))

    state
  end

  defp process_text(_text, _opts, %{enabled?: false} = state), do: {{:error, :disabled}, state}

  defp process_text(text, opts, state) when is_binary(text) do
    if SlashCommands.slash?(text) do
      dispatch_slash(text, state)
    else
      process_inbound_text(text, opts, state)
    end
  end

  defp handle_text_submission(text, opts, state) when is_binary(text) do
    cond do
      escape_text?(text) ->
        cancel_current_turn_state(:operator_escape, state)

      queueable_correction?(text, state) ->
        queue_correction(text, opts, state)

      at_file_reference?(text, state) ->
        read_at_file_reference(text, state)

      async_coding_turn?(text, opts, state) ->
        start_async_coding_turn(text, opts, state)

      true ->
        process_text(text, opts, state)
    end
  end

  defp queueable_correction?(text, state) do
    state.coding_mode? and
      CodingConfig.steer_enabled?() and
      not is_nil(state.current_turn) and
      not SlashCommands.slash?(text)
  end

  defp async_coding_turn?(text, opts, state) do
    state.coding_mode? and
      CodingConfig.steer_enabled?() and
      Keyword.get(opts, :async?, false) and
      not SlashCommands.slash?(text)
  end

  defp queue_correction(text, opts, state) do
    current_turn_id = state.current_turn.turn_id
    emit_output("Queued correction for next coding turn.", state)

    {{:ok, {:queued, current_turn_id}},
     %{state | queued_correction: {text, Keyword.delete(opts, :async?)}}}
  end

  defp start_async_coding_turn(text, opts, state) do
    turn_id = coding_turn_id(opts)
    parent = self()
    {live_region, state} = start_coding_live_region(turn_id, state)

    turn_opts =
      opts
      |> Keyword.delete(:async?)
      |> Keyword.put(:coding_turn?, true)
      |> Keyword.put(:coding_turn_id, turn_id)
      |> Keyword.put(:stream_event_sink, parent)
      |> Keyword.put_new(:surface, "pi_mode")
      |> Keyword.put_new(:coding_session, CodingSession.metadata(state.pi_session))

    task_state = %{state | current_turn: nil, queued_correction: nil}

    case start_turn_task(fn ->
           reply =
             try do
               {reply, _state} = process_inbound_text(text, turn_opts, task_state)
               reply
             rescue
               exception ->
                 {:error, {exception.__struct__, Exception.message(exception)}}
             catch
               kind, reason ->
                 {:error, {kind, Redactor.redact(reason)}}
             end

           send(parent, {:coding_tui_turn_finished, turn_id, reply})
         end) do
      {:ok, pid} ->
        {{:ok, {:accepted, turn_id}},
         %{
           state
           | current_turn: %{
               turn_id: turn_id,
               pid: pid,
               live_region: live_region,
               started_at: timestamp()
             }
         }}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp start_coding_live_region(_turn_id, %{live_screen?: false} = state), do: {nil, state}

  defp start_coding_live_region(turn_id, state) do
    case LiveRegion.start(state.live_screen_server, turn_id, max_text_bytes: state.max_text_bytes) do
      {:ok, live_region} ->
        {live_region, state}

      {:error, reason} ->
        Logger.debug("tui coding live region unavailable: #{inspect(reason)}")
        {nil, %{state | live_screen?: false}}
    end
  rescue
    error ->
      Logger.debug("tui coding live region unavailable: #{Exception.message(error)}")
      {nil, %{state | live_screen?: false}}
  catch
    :exit, reason ->
      Logger.debug("tui coding live region unavailable: #{inspect(reason)}")
      {nil, %{state | live_screen?: false}}
  end

  defp apply_live_stream_event(%{current_turn: %{live_region: live_region} = turn} = state, event) do
    case LiveRegion.apply_event(live_region, event) do
      {:ok, live_region} ->
        %{state | current_turn: %{turn | live_region: live_region}}

      {:error, reason} ->
        Logger.debug("tui coding live stream update failed: #{inspect(reason)}")
        state
    end
  rescue
    error ->
      Logger.debug("tui coding live stream update failed: #{Exception.message(error)}")
      %{state | live_screen?: false}
  catch
    :exit, reason ->
      Logger.debug("tui coding live stream update failed: #{inspect(reason)}")
      %{state | live_screen?: false}
  end

  defp start_queued_correction(%{queued_correction: nil} = state), do: state

  defp start_queued_correction(%{queued_correction: {text, opts}} = state) do
    {_reply, state} =
      start_async_coding_turn(text, Keyword.put(opts, :async?, true), %{
        state
        | queued_correction: nil
      })

    state
  end

  defp cancel_current_turn_state(_reason, %{current_turn: nil} = state),
    do: {{:error, :no_current_turn}, state}

  defp cancel_current_turn_state(reason, state) do
    if CodingConfig.steer_enabled?() do
      turn_id = state.current_turn.turn_id
      reply = cancel_registered_turn(turn_id, reason, 20)
      {reply, state}
    else
      {{:error, :steer_disabled}, state}
    end
  end

  defp cancel_registered_turn(turn_id, reason, retries) do
    case CodingTurnSupervisor.cancel(turn_id, reason) do
      {:ok, result} ->
        {:ok, {:cancel_requested, result}}

      {:error, :not_found} when retries > 0 ->
        Process.sleep(50)
        cancel_registered_turn(turn_id, reason, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_emit_cancel_feedback({:ok, {:cancel_requested, %{turn_id: turn_id}}}, state),
    do: emit_output("Cancellation requested for coding turn #{turn_id}.", state)

  defp maybe_emit_cancel_feedback({:error, :no_current_turn}, state),
    do: emit_output("No coding turn is currently running.", state)

  defp maybe_emit_cancel_feedback({:error, :steer_disabled}, state),
    do: emit_output("Coding steering is disabled.", state)

  defp maybe_emit_cancel_feedback(_reply, _state), do: :ok

  defp coding_turn_id(opts) do
    Keyword.get(opts, :coding_turn_id) ||
      Keyword.get(opts, :turn_id) ||
      "tui-coding-#{Ecto.UUID.generate()}"
  end

  defp start_turn_task(fun) do
    if Process.whereis(AllbertAssist.TaskSupervisor) do
      Task.Supervisor.start_child(AllbertAssist.TaskSupervisor, fun)
    else
      Task.start(fun)
    end
  end

  defp process_inbound_text(text, opts, state) do
    fields = fields(text, opts, state)
    command = ConfirmationCallback.parse_typed_command(fields.text)
    direction = if command == :ignore, do: "inbound", else: "callback"

    case insert_received_event(fields, direction) do
      {:ok, %AllbertAssist.Channels.Event{} = event} ->
        handle_received_event(event, fields, command, state)

      {:ok, :duplicate} ->
        {{:ok, :duplicate}, clear_live_status(state)}

      {:error, reason} ->
        {{:error, reason}, clear_live_status(state)}
    end
  end

  defp dispatch_slash(text, state) do
    with {:ok, context} <- slash_context(text, state),
         {:ok, response, state} <- dispatch_slash_command(text, context, state),
         {:ok, rendered} <-
           Renderer.render_response(response, max_text_bytes: state.max_text_bytes),
         state <- clear_live_status(state),
         :ok <- emit_rendered(rendered, state) do
      {{:ok, {:slash, rendered}}, state}
    else
      {:error, :disabled} ->
        render_unavailable_slash(:disabled, state)

      {:error, :not_mapped} ->
        render_unavailable_slash(:not_mapped, state)
    end
  end

  defp dispatch_slash_command(text, context, state) do
    normalized = String.trim(text)

    if SlashCommands.coding_session_command?(normalized) do
      dispatch_coding_slash(normalized, context, state)
    else
      with {:ok, response} <- SlashCommands.dispatch(normalized, context) do
        {:ok, response, state}
      end
    end
  end

  defp dispatch_coding_slash(text, context, state) do
    case String.split(text, ~r/\s+/, parts: 2, trim: true) do
      ["/pi"] ->
        enter_pi_mode(nil, context, state)

      ["/pi", mode] when mode in ["off", "exit", "quit"] ->
        exit_pi_mode(state)

      ["/pi", path] ->
        enter_pi_mode(path, context, state)

      ["/mode"] ->
        current_pi_mode(state)

      ["/mode", mode] ->
        switch_pi_mode(mode, state)

      ["/model"] ->
        current_pi_model(state)

      ["/model", profile] ->
        switch_pi_model(profile, state)

      ["/clear"] ->
        clear_pi_context(state)

      ["/compact"] ->
        compact_pi_context(state)

      ["/init"] ->
        init_pi_mode(".allbert/pi-mode.md", context, state)

      ["/init", path] ->
        init_pi_mode(path, context, state)

      ["/diff"] ->
        local_coding_response(
          "No Pi-mode diff path provided.",
          "Pi-mode diff had no path.",
          state
        )

      ["/diff", path] ->
        read_pi_path(path, context, state, "diff")

      _other ->
        local_coding_response(
          "Unknown slash command. Type /help for available commands.",
          "Unknown TUI coding slash command.",
          state
        )
    end
  end

  defp enter_pi_mode(path, context, state) do
    case CodingSession.start(path, context) do
      {:ok, session} ->
        response =
          SlashCommands.local_response(
            "Pi-mode entered: cwd_jail=#{session.cwd_jail} model=#{session.model_profile} tokenizer=#{session.prompt.tokenizer} prompt_tokens=#{session.prompt.token_count}/#{session.prompt.token_budget}",
            "Pi-mode entered with pinned cwd jail and coding model profile."
          )

        {:ok, response, %{state | coding_mode?: true, pi_session: session}}

      {:error, :pi_mode_disabled} ->
        local_coding_response(
          "Pi-mode is disabled. Set coding.pi_mode.enabled true before /pi.",
          "Pi-mode entry refused because it is disabled.",
          state
        )

      {:error, reason} ->
        local_coding_response(
          "Pi-mode could not start: #{inspect(Redactor.redact(reason))}.",
          "Pi-mode entry failed.",
          state
        )
    end
  end

  defp exit_pi_mode(%{current_turn: %{turn_id: turn_id}} = state) do
    local_coding_response(
      "Cannot exit Pi-mode while coding turn #{turn_id} is running. Cancel or wait first.",
      "Pi-mode exit refused during active turn.",
      state
    )
  end

  defp exit_pi_mode(state) do
    response = SlashCommands.local_response("Pi-mode exited.", "Pi-mode exited.")
    {:ok, response, %{state | coding_mode?: false, pi_session: nil, queued_correction: nil}}
  end

  defp switch_pi_model(_profile, %{pi_session: nil} = state) do
    local_coding_response(
      "Enter Pi-mode with /pi before switching models.",
      "No Pi-mode session.",
      state
    )
  end

  defp switch_pi_model(profile, state) do
    case CodingSession.switch_model(state.pi_session, profile) do
      {:ok, session} ->
        response =
          SlashCommands.local_response(
            "Pi-mode model switched to #{session.model_profile}.",
            "Pi-mode session model profile switched."
          )

        {:ok, response, %{state | pi_session: session}}

      {:error, reason} ->
        local_coding_response(
          "Model switch failed: #{inspect(Redactor.redact(reason))}.",
          "Pi-mode model switch failed.",
          state
        )
    end
  end

  defp current_pi_model(%{pi_session: nil} = state) do
    local_coding_response(
      "Enter Pi-mode with /pi before reading the model.",
      "No Pi-mode session.",
      state
    )
  end

  defp current_pi_model(state) do
    local_coding_response(
      "Pi-mode model: #{state.pi_session.model_profile}.",
      "Pi-mode model profile read.",
      state
    )
  end

  defp switch_pi_mode(_mode, %{pi_session: nil} = state) do
    local_coding_response(
      "Enter Pi-mode with /pi before switching modes.",
      "No Pi-mode session.",
      state
    )
  end

  defp switch_pi_mode(mode, state) do
    case CodingSession.set_approval_mode(state.pi_session, mode) do
      {:ok, session} ->
        response =
          SlashCommands.local_response(
            "Pi-mode approval mode switched to #{session.approval_mode}.",
            "Pi-mode session approval mode switched."
          )

        {:ok, response, %{state | pi_session: session}}

      {:error, reason} ->
        local_coding_response(
          "Mode switch failed: #{inspect(Redactor.redact(reason))}.",
          "Pi-mode mode switch failed.",
          state
        )
    end
  end

  defp current_pi_mode(%{pi_session: nil} = state) do
    local_coding_response(
      "Enter Pi-mode with /pi before reading the mode.",
      "No Pi-mode session.",
      state
    )
  end

  defp current_pi_mode(state) do
    local_coding_response(
      "Pi-mode approval mode: #{state.pi_session.approval_mode}.",
      "Pi-mode approval mode read.",
      state
    )
  end

  defp clear_pi_context(%{pi_session: nil} = state) do
    local_coding_response(
      "Enter Pi-mode with /pi before clearing context.",
      "No Pi-mode session.",
      state
    )
  end

  defp clear_pi_context(state) do
    session = CodingSession.clear(state.pi_session)

    response =
      SlashCommands.local_response("Pi-mode context cleared.", "Pi-mode context cleared.")

    {:ok, response, %{state | pi_session: session}}
  end

  defp compact_pi_context(%{pi_session: nil} = state) do
    local_coding_response(
      "Enter Pi-mode with /pi before compacting context.",
      "No Pi-mode session.",
      state
    )
  end

  defp compact_pi_context(state) do
    session = CodingSession.compact(state.pi_session)

    response =
      SlashCommands.local_response("Pi-mode context compacted.", "Pi-mode context compacted.")

    {:ok, response, %{state | pi_session: session}}
  end

  defp init_pi_mode(_path, _context, %{pi_session: nil} = state) do
    local_coding_response("Enter Pi-mode with /pi before /init.", "No Pi-mode session.", state)
  end

  defp init_pi_mode(path, context, state) do
    params = %{
      path: String.trim(path),
      content: pi_init_content(state.pi_session),
      source_text: "/init"
    }

    {:ok, response} =
      context
      |> coding_context(state)
      |> run_coding_action("write", params)

    {:ok, maybe_attach_approval_handoff(response, context), state}
  end

  defp read_pi_path(_path, _context, %{pi_session: nil} = state, _label) do
    local_coding_response(
      "Enter Pi-mode with /pi before reading files.",
      "No Pi-mode session.",
      state
    )
  end

  defp read_pi_path(path, context, state, label) do
    params = %{path: String.trim(path), limit: CodingConfig.read_default_limit()}

    {:ok, response} =
      context
      |> coding_context(state)
      |> run_coding_action("read", params)

    response =
      if label == "diff" do
        Map.update(response, :surface_payload, "", &("Read-only diff context:\n" <> &1))
      else
        response
      end

    {:ok, response, state}
  end

  defp local_coding_response(surface_payload, model_payload, state) do
    {:ok, SlashCommands.local_response(surface_payload, model_payload), state}
  end

  defp maybe_attach_approval_handoff(%{status: :needs_confirmation} = response, context) do
    decision = Map.get(response, :permission_decision, %{})

    handoff =
      decision
      |> ApprovalHandoff.pending(response, context)
      |> ApprovalHandoff.to_map()

    Map.put(response, :approval_handoff, handoff)
  end

  defp maybe_attach_approval_handoff(response, _context), do: response

  defp render_unavailable_slash(reason, state) do
    response = SlashCommands.unavailable_response(reason)

    with {:ok, rendered} <-
           Renderer.render_response(response, max_text_bytes: state.max_text_bytes),
         state <- clear_live_status(state),
         :ok <- emit_rendered(rendered, state) do
      {{:ok, {:slash, rendered}}, state}
    else
      {:error, render_reason} ->
        state = clear_live_status(state)

        Logger.debug(
          "tui slash unavailable render failed: #{inspect(Redactor.redact(render_reason))}"
        )

        {{:error, render_reason}, state}
    end
  end

  defp slash_context(text, state) do
    if SlashCommands.requires_identity?(text) do
      with {:ok, user_id} <- resolve_identity(%{external_user_id: state.profile}, state) do
        {:ok, Map.merge(base_slash_context(state), identity_context(user_id, state))}
      end
    else
      {:ok, base_slash_context(state)}
    end
  end

  defp base_slash_context(state) do
    %{
      channel: @channel,
      provider: @provider,
      surface: "tui_slash_command",
      external_user_id: state.profile,
      receiver_account_ref: "tui:#{state.profile}",
      session: %{main?: true},
      request: %{
        channel: @channel,
        provider: @provider,
        surface: "tui_slash_command",
        external_user_id: state.profile,
        receiver_account_ref: "tui:#{state.profile}",
        session: %{main?: true}
      }
    }
    |> maybe_attach_coding_context(state)
  end

  defp identity_context(user_id, state) do
    %{
      actor: %{id: user_id},
      user_id: user_id,
      operator_id: user_id,
      session: %{main?: true},
      request: %{
        channel: @channel,
        provider: @provider,
        surface: "tui_slash_command",
        external_user_id: state.profile,
        receiver_account_ref: "tui:#{state.profile}",
        user_id: user_id,
        operator_id: user_id,
        actor: %{id: user_id},
        session: %{main?: true}
      }
    }
    |> maybe_attach_coding_context(state)
  end

  defp maybe_attach_coding_context(context, %{pi_session: nil}), do: context

  defp maybe_attach_coding_context(context, state) do
    Map.put(context, :coding, CodingSession.metadata(state.pi_session))
  end

  defp coding_context(context, state) do
    context
    |> Map.put(:channel, %{name: :tui, trust: :local})
    |> Map.put(:surface, "pi_mode")
    |> Map.put(:session, %{main?: true})
    |> Map.put(:coding, CodingSession.metadata(state.pi_session))
  end

  defp fields(text, opts, state) do
    event_id =
      Keyword.get(opts, :external_event_id) ||
        "tui-#{Ecto.UUID.generate()}"

    %{
      text: String.trim(text),
      external_event_id: event_id,
      external_user_id: Keyword.get(opts, :external_user_id, state.profile),
      external_chat_id: Keyword.get(opts, :external_chat_id, state.profile),
      external_message_id: Keyword.get(opts, :external_message_id, event_id),
      receiver_account_ref: "tui:#{state.profile}",
      provider_thread_ref: %{
        provider: @provider,
        profile: state.profile,
        provider_thread_root: "profile:#{state.profile}"
      },
      coding_turn?: Keyword.get(opts, :coding_turn?),
      coding_turn_id: Keyword.get(opts, :coding_turn_id) || Keyword.get(opts, :turn_id),
      stream_event_sink: Keyword.get(opts, :stream_event_sink),
      coding_session:
        Keyword.get(opts, :coding_session) || CodingSession.metadata(state.pi_session),
      surface: Keyword.get(opts, :surface),
      raw_summary: "tui input #{event_id}"
    }
  end

  defp insert_received_event(fields, direction) do
    %{
      channel: @channel,
      provider: @provider,
      direction: direction,
      external_event_id: fields.external_event_id,
      external_user_id: fields.external_user_id,
      external_chat_id: fields.external_chat_id,
      external_message_id: fields.external_message_id,
      status: "received",
      payload_summary: fields.raw_summary
    }
    |> Channels.create_event()
    |> event_result()
  end

  defp handle_received_event(event, fields, command, state) do
    with :ok <- validate_text(fields.text),
         {:ok, user_id} <- resolve_identity(fields, state),
         {:ok, inbound_trust} <- authorize_inbound(fields, user_id, command),
         session_id <-
           Channels.derive_session_id(@channel, fields.external_user_id, fields.external_chat_id),
         {:ok, response} <-
           process_text_or_callback(command, fields, state, user_id, session_id, inbound_trust),
         {:ok, rendered} <-
           Renderer.render_response(response, max_text_bytes: state.max_text_bytes),
         state <- clear_live_status(state),
         :ok <- emit_rendered(rendered, state),
         {:ok, event} <- mark_processed(event, response, user_id, session_id) do
      {{:ok, {:processed, event, rendered}}, state}
    else
      {:error, reason} ->
        state = clear_live_status(state)
        Logger.debug("tui event rejected: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {{:ok, :rejected}, state}
    end
  end

  defp validate_text(text) when is_binary(text) and text != "", do: :ok
  defp validate_text(_text), do: {:error, :empty_text}

  defp resolve_identity(fields, state) do
    Identity.resolve(
      @channel,
      fields.external_user_id,
      Map.get(state.settings, "identity_map", [])
    )
  end

  defp authorize_inbound(fields, user_id, command) do
    InboundTrust.authorize(%{
      user_id: user_id,
      channel: @channel,
      provider: @provider,
      surface: tui_surface(command),
      external_user_id: fields.external_user_id,
      external_chat_id: fields.external_chat_id,
      receiver_account_ref: fields.receiver_account_ref
    })
  end

  defp tui_surface(:ignore), do: "tui_prompt"
  defp tui_surface({:ok, _action, _confirmation_id}), do: "tui_typed_command"

  defp process_text_or_callback(:ignore, fields, _state, user_id, session_id, inbound_trust) do
    submit_runtime(fields, user_id, session_id, inbound_trust)
  end

  defp process_text_or_callback(
         {:ok, action, confirmation_id},
         fields,
         state,
         user_id,
         session_id,
         _inbound_trust
       ) do
    with {:ok, response} <-
           ConfirmationCallback.run(%{
             action: action,
             confirmation_id: confirmation_id,
             channel: @channel,
             user_id: user_id,
             session_id: session_id,
             surface: "tui_typed_command",
             identity_proof: identity_proof(fields, state, user_id),
             resolver_metadata: %{
               provider: @provider,
               external_event_id: fields.external_event_id,
               external_user_id: fields.external_user_id,
               external_chat_id: fields.external_chat_id,
               external_message_id: fields.external_message_id,
               command: "ALLBERT:#{String.upcase(to_string(action))}:#{confirmation_id}"
             }
           }) do
      {:ok,
       %{
         model_payload: ConfirmationCallback.reply_text(response),
         surface_payload: Renderer.confirmation_reply(response),
         status: :completed
       }}
    end
  end

  defp identity_proof(fields, state, user_id) do
    %{
      channel: @channel,
      user_id: user_id,
      external_user_id: fields.external_user_id,
      external_chat_id: fields.external_chat_id,
      receiver_account_ref: fields.receiver_account_ref,
      identity_map: Map.get(state.settings, "identity_map", [])
    }
  end

  defp submit_runtime(fields, user_id, session_id, inbound_trust) do
    metadata =
      %{
        channel: @channel,
        provider: @provider,
        external_event_id: fields.external_event_id,
        external_user_id: fields.external_user_id,
        external_chat_id: fields.external_chat_id,
        external_message_id: fields.external_message_id,
        receiver_account_ref: fields.receiver_account_ref,
        provider_thread_ref: fields.provider_thread_ref,
        inbound_trust: inbound_trust
      }
      |> maybe_put(:coding_turn?, fields.coding_turn?)
      |> maybe_put(:coding_turn_id, fields.coding_turn_id)
      |> maybe_put(:coding, non_empty_map(fields.coding_session))
      |> maybe_put(:surface, fields.surface)

    %{
      text: fields.text,
      channel: @channel,
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      channel_thread_ref: channel_thread_ref(fields),
      provider_message_id: fields.external_message_id,
      metadata: metadata
    }
    |> maybe_put(:stream_event_sink, fields.stream_event_sink)
    |> maybe_put(:coding_turn?, fields.coding_turn?)
    |> maybe_put(:coding_turn_id, fields.coding_turn_id)
    |> Runtime.submit_user_input()
  end

  defp channel_thread_ref(fields) do
    %{
      channel: @channel,
      receiver_account_ref: fields.receiver_account_ref,
      provider_thread_ref: fields.provider_thread_ref
    }
  end

  defp run_coding_action(context, action_name, params) do
    AllbertAssist.Actions.Runner.run(action_name, params, context)
  end

  defp at_file_reference?(text, state) do
    state.coding_mode? and not is_nil(state.pi_session) and
      Regex.match?(~r/^@[^\s]+$/, String.trim(text))
  end

  defp read_at_file_reference(text, state) do
    path = text |> String.trim() |> String.trim_leading("@")
    context = base_slash_context(state)

    with {:ok, user_id} <- resolve_identity(%{external_user_id: state.profile}, state) do
      context =
        context
        |> Map.merge(identity_context(user_id, state))
        |> coding_context(state)

      {:ok, response, state} = read_pi_path(path, context, state, "@file")

      with {:ok, rendered} <-
             Renderer.render_response(response, max_text_bytes: state.max_text_bytes),
           state <- clear_live_status(state),
           :ok <- emit_rendered(rendered, state) do
        {{:ok, {:at_file, rendered}}, state}
      end
    else
      {:error, reason} ->
        render_unavailable_slash(reason, state)
    end
  end

  defp pi_init_content(session) do
    """
    # Allbert Pi-Mode

    cwd_jail: #{session.cwd_jail}
    model_profile: #{session.model_profile}
    prompt_tokens: #{session.prompt.token_count}/#{session.prompt.token_budget}

    Tools: #{Enum.map_join(session.prompt.tools, ", ", & &1.name)}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp non_empty_map(map) when is_map(map) and map_size(map) > 0, do: map
  defp non_empty_map(_map), do: nil

  defp emit_rendered(rendered, state) do
    Enum.each(rendered, &emit_output(&1, state))
    :ok
  end

  defp emit_output(line, %{output_fun: output_fun}) when is_function(output_fun, 1) do
    output_fun.(line)
  end

  defp emit_output(line, _state), do: default_output(line)

  defp mark_processed(event, response, user_id, session_id) do
    Channels.update_event(event, %{
      status: "processed",
      user_id: user_id,
      session_id: session_id,
      thread_id: response_value(response, :thread_id),
      input_signal_id: response_value(response, :input_signal_id),
      trace_id: response_value(response, :trace_id)
    })
  end

  defp mark_rejected_or_failed(event, reason) do
    status =
      if reason in [
           :empty_text,
           :not_mapped,
           :disabled,
           :wrong_channel,
           :wrong_user,
           :unsupported_callback_action,
           :channel_message_inbound_denied
         ],
         do: "rejected",
         else: "failed"

    Channels.update_event(event, %{status: status, reason: inspect(Redactor.redact(reason))})
  end

  defp event_result({:ok, %AllbertAssist.Channels.Event{} = event}), do: {:ok, event}

  defp event_result({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    if Keyword.has_key?(errors, :external_event_id) do
      external_event_id = Ecto.Changeset.get_field(changeset, :external_event_id)

      case Channels.get_event_by_external_id(@channel, external_event_id) do
        %AllbertAssist.Channels.Event{} -> {:ok, :duplicate}
        nil -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp supervised_pid(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {"tui", pid, :worker, _modules} when is_pid(pid) -> {:ok, pid}
      {__MODULE__, pid, :worker, _modules} when is_pid(pid) -> {:ok, pid}
      _child -> nil
    end)
    |> case do
      {:ok, pid} -> {:ok, pid}
      nil -> {:error, :tui_child_not_started}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp wait_for_supervised_child(supervisor, pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        if launcher_exit?(reason) do
          reason
        else
          Logger.debug("tui supervised child exited; waiting for restart: #{inspect(reason)}")

          with {:ok, restarted_pid} <- await_supervised_restart(supervisor, pid) do
            wait_for_supervised_child(supervisor, restarted_pid)
          end
        end
    end
  end

  defp await_supervised_restart(supervisor, old_pid, attempts \\ 50)

  defp await_supervised_restart(_supervisor, _old_pid, 0),
    do: {:error, :tui_child_not_restarted}

  defp await_supervised_restart(supervisor, old_pid, attempts) do
    case supervised_pid(supervisor) do
      {:ok, pid} when pid != old_pid ->
        {:ok, pid}

      _other ->
        Process.sleep(100)
        await_supervised_restart(supervisor, old_pid, attempts - 1)
    end
  end

  defp launcher_exit?(:normal), do: true
  defp launcher_exit?(:shutdown), do: true
  defp launcher_exit?({:shutdown, _reason}), do: true
  defp launcher_exit?(_reason), do: false

  defp update_live_status(%{live_screen?: false} = state, _status), do: state
  defp update_live_status(state, :ready), do: clear_live_status(state)

  defp update_live_status(%{live_status_active?: false} = state, status) do
    server = state.live_screen_server

    add_live_block(server, state.profile)

    Owl.LiveScreen.update(
      server,
      :allbert_tui_status,
      Renderer.status(state.profile, status)
    )

    Owl.LiveScreen.await_render(server)
    %{state | live_status_active?: true}
  rescue
    error ->
      Logger.debug("tui live screen unavailable: #{Exception.message(error)}")
      %{state | live_screen?: false, live_status_active?: false}
  catch
    :exit, reason ->
      Logger.debug("tui live screen unavailable: #{inspect(reason)}")
      %{state | live_screen?: false, live_status_active?: false}
  end

  defp update_live_status(state, status) do
    Owl.LiveScreen.update(
      state.live_screen_server,
      :allbert_tui_status,
      Renderer.status(state.profile, status)
    )

    Owl.LiveScreen.await_render(state.live_screen_server)
    state
  rescue
    error ->
      Logger.debug("tui live screen unavailable: #{Exception.message(error)}")
      %{state | live_screen?: false, live_status_active?: false}
  catch
    :exit, reason ->
      Logger.debug("tui live screen unavailable: #{inspect(reason)}")
      %{state | live_screen?: false, live_status_active?: false}
  end

  defp clear_live_status(%{live_status_active?: false} = state), do: state

  defp clear_live_status(state) do
    Owl.LiveScreen.update(state.live_screen_server, :allbert_tui_status, [])
    Owl.LiveScreen.await_render(state.live_screen_server)
    Owl.LiveScreen.flush(state.live_screen_server)
    %{state | live_status_active?: false}
  rescue
    error ->
      Logger.debug("tui live screen unavailable: #{Exception.message(error)}")
      %{state | live_screen?: false, live_status_active?: false}
  catch
    :exit, reason ->
      Logger.debug("tui live screen unavailable: #{inspect(reason)}")
      %{state | live_screen?: false, live_status_active?: false}
  end

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp escape_text?(text) when is_binary(text), do: normalize_input(text) == :escape

  defp default_input(prompt) do
    prompt
    |> Owl.Data.to_chardata()
    |> IO.gets()
    |> normalize_input()
  end

  defp normalize_input(:escape), do: :escape
  defp normalize_input({:escape, _reason}), do: :escape

  defp normalize_input(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "\e" -> :escape
      text -> text
    end
  end

  defp normalize_input(_value), do: nil

  defp default_output(line), do: Owl.IO.puts(line)
end
