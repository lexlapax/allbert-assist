defmodule AllbertAssist.Channels.TUI.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.InboundTrust
  alias AllbertAssist.Channels.TUI.Renderer
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.Redactor

  @provider "terminal"
  @channel "tui"
  @quit_commands MapSet.new(["/quit", "/exit"])

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

  def run_forever(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:name, nil)
      |> Keyword.put_new(:enabled?, true)
      |> Keyword.put_new(:auto_input?, true)
      |> Keyword.put_new(:live_screen?, true)

    with {:ok, pid} <- start_link(opts) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, reason} -> reason
      end
    end
  end

  @impl true
  def init(opts) do
    state =
      opts
      |> load_state()
      |> maybe_start_live_screen()
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
      settings: settings,
      profile: profile,
      live_screen?: Keyword.get(opts, :live_screen?, false),
      live_screen_server: Keyword.get(opts, :live_screen_server, Owl.LiveScreen),
      input_fun: Keyword.get(opts, :input_fun, &default_input/1),
      output_fun: Keyword.get(opts, :output_fun, &default_output/1),
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

  defp maybe_start_live_screen(%{live_screen?: false} = state), do: state

  defp maybe_start_live_screen(state) do
    add_live_block(state.live_screen_server, state.profile)
    state
  rescue
    error ->
      Logger.debug("tui live screen unavailable: #{Exception.message(error)}")
      %{state | live_screen?: false}
  catch
    :exit, reason ->
      Logger.debug("tui live screen unavailable: #{inspect(reason)}")
      %{state | live_screen?: false}
  end

  defp add_live_block(server, profile) do
    Owl.LiveScreen.add_block(server, :allbert_tui_status,
      state: Renderer.status(profile, :starting),
      render: &Function.identity/1
    )
  end

  defp emit_banner(%{enabled?: false} = state), do: state

  defp emit_banner(state) do
    state.profile
    |> Renderer.banner()
    |> Enum.each(state.output_fun)

    state
  end

  defp process_text(_text, _opts, %{enabled?: false} = state), do: {{:error, :disabled}, state}

  defp process_text(text, opts, state) do
    fields = fields(text, opts, state)

    case insert_received_event(fields) do
      {:ok, %AllbertAssist.Channels.Event{} = event} ->
        {handle_received_event(event, fields, state), state}

      {:ok, :duplicate} ->
        {{:ok, :duplicate}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp fields(text, opts, state) do
    event_id =
      Keyword.get(opts, :external_event_id) ||
        "tui-#{System.unique_integer([:positive, :monotonic])}"

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

  defp insert_received_event(fields) do
    %{
      channel: @channel,
      provider: @provider,
      direction: "inbound",
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

  defp handle_received_event(event, fields, state) do
    with :ok <- validate_text(fields.text),
         {:ok, user_id} <- resolve_identity(fields, state),
         {:ok, inbound_trust} <- authorize_inbound(fields, user_id),
         session_id <-
           Channels.derive_session_id(@channel, fields.external_user_id, fields.external_chat_id),
         {:ok, response} <- submit_runtime(fields, user_id, session_id, inbound_trust),
         {:ok, rendered} <-
           Renderer.render_response(response, max_text_bytes: state.max_text_bytes),
         :ok <- emit_rendered(rendered, state),
         {:ok, event} <- mark_processed(event, response, user_id, session_id) do
      {:ok, {:processed, event, rendered}}
    else
      {:error, reason} ->
        Logger.debug("tui event rejected: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
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

  defp authorize_inbound(fields, user_id) do
    InboundTrust.authorize(%{
      user_id: user_id,
      channel: @channel,
      provider: @provider,
      surface: "tui_prompt",
      external_user_id: fields.external_user_id,
      external_chat_id: fields.external_chat_id,
      receiver_account_ref: fields.receiver_account_ref
    })
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
    Enum.each(rendered, state.output_fun)
    update_live_status(state, :ready)
    :ok
  end

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
      if reason in [:empty_text, :not_mapped, :disabled, :channel_message_inbound_denied],
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

  defp update_live_status(%{live_screen?: false} = state, _status), do: state

  defp update_live_status(state, status) do
    Owl.LiveScreen.update(
      state.live_screen_server,
      :allbert_tui_status,
      Renderer.status(state.profile, status)
    )

    state
  rescue
    _error -> %{state | live_screen?: false}
  catch
    :exit, _reason -> %{state | live_screen?: false}
  end

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp default_input(prompt), do: Owl.IO.input(label: prompt)
  defp default_output(line), do: Owl.IO.puts(line)
end
