defmodule AllbertAssist.Channels.TUI.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.ConfirmationCallback
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.InboundTrust
  alias AllbertAssist.Channels.TUI.Renderer
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
    {reply, state} = process_text(text, opts, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:read_input, state) do
    state = update_live_status(state, :ready)

    case state.input_fun.(Renderer.prompt(state.profile)) do
      command when is_binary(command) ->
        if MapSet.member?(@quit_commands, command) do
          {:stop, :normal, state}
        else
          state = update_live_status(state, :processing)
          {_reply, state} = process_text(command, [], state)
          Process.send_after(self(), :read_input, 0)
          {:noreply, state}
        end

      _other ->
        Process.send_after(self(), :read_input, 0)
        {:noreply, state}
    end
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
      max_text_bytes: Map.get(settings, "max_text_bytes", 12_000)
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

  defp process_text(text, opts, state) do
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
    Runtime.submit_user_input(%{
      text: fields.text,
      channel: @channel,
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      channel_thread_ref: channel_thread_ref(fields),
      provider_message_id: fields.external_message_id,
      metadata: %{
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
    })
  end

  defp channel_thread_ref(fields) do
    %{
      channel: @channel,
      receiver_account_ref: fields.receiver_account_ref,
      provider_thread_ref: fields.provider_thread_ref
    }
  end

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

  defp default_input(prompt) do
    prompt
    |> Owl.Data.to_chardata()
    |> IO.gets()
    |> normalize_input()
  end

  defp normalize_input(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_input(_value), do: nil

  defp default_output(line), do: Owl.IO.puts(line)
end
