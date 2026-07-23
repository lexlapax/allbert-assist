defmodule AllbertAssist.Channels.Discord.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.ConfirmationCallback
  alias AllbertAssist.Channels.Discord.Client.GatewayPort
  alias AllbertAssist.Channels.Discord.Client
  alias AllbertAssist.Channels.Discord.Parser
  alias AllbertAssist.Channels.Discord.Renderer
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.InboundTrust
  alias AllbertAssist.Channels.NotifyConsentCallback
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.Redactor

  @provider "discord_gateway"

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  def simulate_gateway_event(server \\ __MODULE__, event, timeout \\ 5_000) do
    GenServer.call(server, {:simulate_gateway_event, event}, timeout)
  end

  @doc """
  Report the adapter's live gateway transport status for the provider doctor.

  Returns `:not_started` when no adapter process is running (so the doctor never
  reports a connection that does not exist) and `:unavailable` if the running
  adapter cannot answer in time. A running adapter returns its raw status
  (`:running` | `:disabled` | `{:error, _}` | `{:not_started, _}`); the doctor
  normalizes and redacts before surfacing it.
  """
  def status(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :not_started
      pid -> GenServer.call(pid, :status, 1_000)
    end
  catch
    :exit, _reason -> :unavailable
  end

  @impl true
  def init(opts) do
    state =
      opts
      |> load_state()
      |> maybe_start_gateway()

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.gateway_status, state}
  end

  def handle_call({:simulate_gateway_event, event}, _from, state) do
    {reply, state} = process_gateway_event(event, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:discord_gateway_event, event}, state) do
    {_reply, state} = process_gateway_event(event, state)
    {:noreply, state}
  end

  defp load_state(opts) do
    settings =
      case Channels.channel_settings("discord") do
        {:ok, settings} -> settings
        {:error, _reason} -> %{}
      end

    enabled? = Map.get(settings, "enabled", false)
    client_opts = Keyword.get(opts, :client_opts, [])

    client_opts =
      if enabled? do
        Keyword.put_new(client_opts, :mode, :real)
      else
        client_opts
      end

    %{
      enabled?: Map.get(settings, "enabled", false),
      settings: settings,
      token_ref: Map.get(settings, "bot_token_ref", "secret://channels/discord/bot_token"),
      client_opts: client_opts,
      diagnostics: AllbertDiscord.Settings.Fragment.required_when_enabled(settings),
      gateway_port_module: Keyword.get(opts, :gateway_port, GatewayPort.Real),
      gateway_opts: Keyword.get(opts, :gateway_opts, []),
      gateway_port: nil,
      gateway_status: :not_started,
      last_ready: nil
    }
  end

  defp maybe_start_gateway(%{enabled?: false} = state), do: %{state | gateway_status: :disabled}

  defp maybe_start_gateway(%{diagnostics: diagnostics} = state) when diagnostics != [] do
    %{state | gateway_status: {:not_started, {:invalid_settings, diagnostics}}}
  end

  defp maybe_start_gateway(state) do
    opts =
      [
        owner: self(),
        token_ref: state.token_ref,
        intents: Map.get(state.settings, "gateway_intents", []),
        heartbeat_jitter?:
          Map.get(state.settings, "gateway", %{}) |> Map.get("heartbeat_jitter", true),
        reconnect_max_backoff_ms:
          Map.get(state.settings, "gateway", %{}) |> Map.get("reconnect_max_backoff_ms", 30_000),
        client_opts: state.client_opts
      ]
      |> Keyword.merge(state.gateway_opts)

    case state.gateway_port_module.start_link(opts) do
      {:ok, pid} ->
        %{state | gateway_port: pid, gateway_status: :running}

      {:error, reason} ->
        Logger.debug("discord gateway not started: #{inspect(Redactor.redact(reason))}")
        %{state | gateway_status: {:error, reason}}
    end
  end

  defp process_gateway_event(event, state) do
    case Parser.parse_gateway_event(event) do
      {:ready, fields} ->
        {{:ok, {:ready, fields}}, %{state | last_ready: DateTime.utc_now()}}

      {:message_create, fields} ->
        {handle_message(fields, state), state}

      {:interaction_create, fields} ->
        {handle_interaction(fields, state), state}

      {:unsupported, fields} ->
        {insert_rejected_event(fields.external_event_id, fields.type), state}

      {:malformed, reason} ->
        {{:error, {:malformed, reason}}, state}
    end
  end

  defp handle_message(fields, state) do
    case insert_received_event(fields, "inbound") do
      {:ok, %AllbertAssist.Channels.Event{} = event} ->
        process_received_message(event, fields, state)

      {:ok, :duplicate} ->
        {:ok, :duplicate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_interaction(fields, state) do
    # The interaction acknowledgement is fired by the gateway transport
    # (GatewayPort) before this event is forwarded — a Discord protocol
    # obligation kept off the adapter's serial mailbox so a slow message turn
    # cannot delay it past the 3s window. The adapter only resolves the business
    # callback (confirmation), symmetric with the Slack adapter, whose envelope
    # ack is owned by SocketModePort (M8R3).
    case insert_received_event(fields, "callback") do
      {:ok, %AllbertAssist.Channels.Event{} = event} ->
        process_callback(event, fields, state)

      {:ok, :duplicate} ->
        {:ok, :duplicate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_received_event(fields, direction) do
    %{
      channel: "discord",
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

  defp insert_rejected_event(external_event_id, reason) do
    %{
      channel: "discord",
      provider: @provider,
      direction: "inbound",
      external_event_id: external_event_id,
      status: "rejected",
      reason: to_string(reason),
      payload_summary: "unsupported discord event"
    }
    |> Channels.create_event()
    |> event_result(:rejected)
  end

  defp process_received_message(event, fields, state) do
    with :ok <- validate_allowlist(fields, state),
         :ok <- validate_text(fields, state),
         :ok <- reject_echo(fields),
         {:ok, user_id} <- resolve_identity(fields, state),
         {:ok, inbound_trust} <- authorize_inbound(fields, user_id, :message),
         session_id <- session_id(fields),
         {:ok, event, rendered} <-
           process_text_or_runtime(event, fields, state, user_id, session_id, inbound_trust) do
      {:ok, {:processed, event, rendered}}
    else
      {:error, reason} ->
        Logger.debug("discord simulated event rejected: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  defp process_text_or_runtime(event, fields, state, user_id, session_id, inbound_trust) do
    case ConfirmationCallback.parse_typed_command(fields.text) do
      {:ok, action, confirmation_id} ->
        with {:ok, response} <-
               run_confirmation_callback(
                 fields,
                 state,
                 user_id,
                 session_id,
                 action,
                 confirmation_id,
                 inbound_trust
               ),
             {:ok, rendered} <- render_confirmation_response(response, state),
             {:ok, _delivered} <- deliver_rendered(fields, rendered, state),
             {:ok, event} <- mark_callback_processed(event, response, user_id, session_id) do
          {:ok, event, rendered}
        end

      :ignore ->
        with {:ok, response} <- submit_runtime(fields, user_id, session_id, inbound_trust),
             {:ok, rendered} <- Renderer.render_response(response, renderer_opts(state)),
             {:ok, delivered} <-
               Runtime.track_delivery(response, %{channel: "discord"}, fn ->
                 deliver_rendered(fields, rendered, state)
               end),
             :ok <- record_outbound_refs(response, fields, delivered),
             :ok <- Runtime.acknowledge_deliveries(response, %{channel: "discord"}),
             {:ok, event} <- mark_processed(event, response, user_id, session_id) do
          {:ok, event, rendered}
        end
    end
  end

  defp process_callback(event, fields, state) do
    with :ok <- validate_interaction_allowlist(fields, state),
         {:ok, user_id} <- resolve_identity(fields, state),
         {:ok, inbound_trust} <- authorize_inbound(fields, user_id, :callback),
         session_id <-
           Channels.derive_session_id("discord", fields.external_user_id, fields.external_chat_id),
         {:ok, response} <-
           run_confirmation_callback(fields, state, user_id, session_id, inbound_trust),
         {:ok, rendered} <- render_confirmation_response(response, state),
         {:ok, _delivered} <- deliver_callback_result(fields, rendered, state),
         {:ok, event} <- mark_callback_processed(event, response, user_id, session_id) do
      {:ok, {:processed, event, rendered}}
    else
      {:error, reason} ->
        Logger.debug("discord callback rejected: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  defp validate_allowlist(fields, state) do
    allowed_guild_ids = Map.get(state.settings, "allowed_guild_ids", [])
    allowed_channel_ids = Map.get(state.settings, "allowed_channel_ids", [])

    cond do
      fields.dm? ->
        :ok

      fields.guild_id not in allowed_guild_ids ->
        {:error, :guild_not_allowed}

      allowed_channel_ids != [] and fields.channel_id not in allowed_channel_ids and
          fields.parent_channel_id not in allowed_channel_ids ->
        {:error, :channel_not_allowed}

      true ->
        :ok
    end
  end

  defp validate_interaction_allowlist(fields, state) do
    allowed_guild_ids = Map.get(state.settings, "allowed_guild_ids", [])
    allowed_channel_ids = Map.get(state.settings, "allowed_channel_ids", [])

    cond do
      is_nil(fields.guild_id) ->
        :ok

      fields.guild_id not in allowed_guild_ids ->
        {:error, :guild_not_allowed}

      allowed_channel_ids != [] and fields.channel_id not in allowed_channel_ids ->
        {:error, :channel_not_allowed}

      true ->
        :ok
    end
  end

  defp validate_text(fields, state) do
    max_text_bytes = Map.get(state.settings, "max_text_bytes", 2000)

    cond do
      not is_binary(fields.text) or String.trim(fields.text) == "" ->
        {:error, :empty_text}

      byte_size(fields.text) > max_text_bytes ->
        {:error, :text_too_large}

      true ->
        :ok
    end
  end

  defp reject_echo(fields) do
    if ChannelThread.echo?(%{
         channel: "discord",
         receiver_account_ref: fields.receiver_account_ref,
         provider_message_id: fields.external_message_id
       }) do
      {:error, :echo_suppressed}
    else
      :ok
    end
  end

  defp resolve_identity(fields, state) do
    Identity.resolve(
      "discord",
      fields.external_user_id,
      Map.get(state.settings, "identity_map", [])
    )
  end

  defp authorize_inbound(fields, user_id, surface) do
    InboundTrust.authorize(%{
      user_id: user_id,
      channel: "discord",
      provider: @provider,
      surface: "discord_#{surface}",
      external_user_id: fields.external_user_id,
      external_chat_id: fields.external_chat_id,
      receiver_account_ref: Map.get(fields, :receiver_account_ref)
    })
  end

  defp session_id(fields) do
    Channels.derive_session_id(
      "discord",
      fields.external_user_id,
      fields.thread_channel_id || fields.channel_id
    )
  end

  defp submit_runtime(fields, user_id, session_id, inbound_trust) do
    Runtime.submit_user_input(%{
      text: fields.text,
      channel: "discord",
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      channel_thread_ref: fields.channel_thread_ref,
      provider_message_id: fields.external_message_id,
      metadata: %{
        channel: "discord",
        provider: @provider,
        external_event_id: fields.external_event_id,
        external_user_id: fields.external_user_id,
        external_chat_id: fields.external_chat_id,
        external_message_id: fields.external_message_id,
        receiver_account_ref: fields.receiver_account_ref,
        provider_thread_ref: fields.provider_thread_ref,
        message_reference: fields.message_reference,
        inbound_trust: inbound_trust
      }
    })
  end

  defp renderer_opts(state) do
    [
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 2000),
      render_buttons: Map.get(state.settings, "render_approval_buttons", true)
    ]
  end

  defp deliver_rendered(fields, rendered, state) do
    rendered
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {payload, index}, {:ok, delivered} ->
      payload = put_reply_reference(payload, fields)

      case Client.create_message(
             state.token_ref,
             fields.thread_channel_id || fields.channel_id,
             payload,
             state.client_opts
           ) do
        {:ok, message} ->
          {:cont, {:ok, delivered ++ [%{part_id: to_string(index), message: message}]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp run_confirmation_callback(fields, state, user_id, session_id, inbound_trust) do
    run_confirmation_callback(
      fields,
      state,
      user_id,
      session_id,
      fields.verb,
      fields.confirmation_id,
      inbound_trust
    )
  end

  defp run_confirmation_callback(
         fields,
         _state,
         user_id,
         session_id,
         :notify_consent,
         _confirmation_id,
         _inbound_trust
       ) do
    result =
      NotifyConsentCallback.run(%{
        channel: "discord",
        user_id: user_id,
        session_id: session_id,
        resolver_metadata: %{external_user_id: fields.external_user_id}
      })

    {:ok, NotifyConsentCallback.response(result)}
  end

  defp run_confirmation_callback(
         fields,
         state,
         user_id,
         session_id,
         action,
         confirmation_id,
         inbound_trust
       ) do
    ConfirmationCallback.run(%{
      action: action,
      confirmation_id: confirmation_id,
      channel: "discord",
      user_id: user_id,
      identity_proof: identity_proof(fields, state, user_id),
      session_id: session_id,
      surface: "discord_interaction",
      resolver_metadata: %{
        provider: @provider,
        external_event_id: fields.external_event_id,
        external_user_id: fields.external_user_id,
        external_chat_id: fields.external_chat_id,
        external_message_id: fields.external_message_id,
        callback_data: callback_marker(fields),
        inbound_trust: inbound_trust
      }
    })
  end

  defp identity_proof(fields, state, user_id) do
    %{
      channel: "discord",
      external_user_id: fields.external_user_id,
      user_id: user_id,
      identity_map: Map.get(state.settings, "identity_map", []),
      receiver_account_ref: Map.get(fields, :receiver_account_ref),
      external_chat_id: fields.external_chat_id
    }
  end

  defp callback_marker(fields), do: Map.get(fields, :callback_data) || Map.get(fields, :text)

  defp render_confirmation_response(response, state) do
    Renderer.render_response(%{message: ConfirmationCallback.reply_text(response)},
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 2000),
      render_buttons: false
    )
  end

  defp deliver_callback_result(fields, rendered, state) do
    delivered =
      rendered
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {payload, index}, {:ok, delivered} ->
        case Client.create_message(
               state.token_ref,
               fields.channel_id || fields.external_chat_id,
               payload,
               state.client_opts
             ) do
          {:ok, message} ->
            {:cont, {:ok, delivered ++ [%{part_id: to_string(index), message: message}]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    delivered
  end

  defp put_reply_reference(payload, %{message_reference: nil}), do: payload

  defp put_reply_reference(payload, fields) do
    Map.put(payload, :message_reference, fields.message_reference)
  end

  defp record_outbound_refs(response, fields, delivered) do
    delivered
    |> Enum.reduce_while(:ok, fn delivered_part, :ok ->
      message = delivered_part.message

      attrs =
        fields.channel_thread_ref
        |> Map.put(:canonical_message_id, response_value(response, :assistant_message_id))
        |> Map.put(:canonical_thread_id, response_value(response, :thread_id))
        |> Map.put(:provider_message_id, Map.get(message, "id"))
        |> Map.put(:part_id, delivered_part.part_id)
        |> Map.put(:direction, :out)

      case ChannelThread.record_message_ref(attrs) do
        {:ok, _ref} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

  defp mark_callback_processed(event, response, user_id, session_id) do
    Channels.update_event(event, %{
      status: "processed",
      user_id: user_id,
      session_id: session_id,
      input_signal_id:
        response_value(response_value(response, :runner_metadata) || %{}, :requested_signal_id)
    })
  end

  defp mark_rejected_or_failed(event, reason) do
    status =
      case reason do
        reason
        when reason in [
               :guild_not_allowed,
               :channel_not_allowed,
               :not_mapped,
               :disabled,
               :wrong_user,
               :wrong_channel,
               :not_found,
               :channel_message_inbound_denied,
               :unsupported_callback_action
             ] ->
          "rejected"

        _reason ->
          "failed"
      end

    Channels.update_event(event, %{status: status, reason: inspect(Redactor.redact(reason))})
  end

  defp event_result({:ok, %AllbertAssist.Channels.Event{} = event}, success),
    do: {:ok, success || event}

  defp event_result({:error, %Ecto.Changeset{errors: errors} = changeset}, _success) do
    if Keyword.has_key?(errors, :external_event_id) do
      {:ok, :duplicate}
    else
      {:error, changeset}
    end
  end

  defp event_result(result), do: event_result(result, nil)

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  # v0.54 M10 (ADR 0063): outbound compose boundary callback. `target` is a Discord
  # channel id.
  @doc false
  def deliver_outbound(target, body, opts) when is_binary(target) and is_binary(body) do
    thread = Keyword.get(opts, :thread, %{})
    reference_id = Map.get(thread, "external_message_id") || Map.get(thread, :external_message_id)

    payload =
      if is_binary(reference_id),
        do: %{content: body, message_reference: %{message_id: reference_id}},
        else: %{content: body}

    case AllbertAssist.Channels.channel_settings("discord") do
      {:ok, settings} ->
        token_ref = Map.get(settings, "bot_token_ref", "secret://channels/discord/bot_token")

        req_options = Keyword.get(opts, :req_options, [])

        case Client.create_message(token_ref, target, payload, req_options) do
          {:ok, result} -> {:ok, %{channel: "discord", target: target, result: result}}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :discord_not_configured}
    end
  end


  @doc false
  def edit_outbound(target, provider_message_id, body, opts)
      when is_binary(target) and is_binary(provider_message_id) and is_binary(body) do
    with {:ok, settings} <- AllbertAssist.Channels.channel_settings("discord") do
      token_ref = Map.get(settings, "bot_token_ref", "secret://channels/discord/bot_token")
      req_options = Keyword.get(opts, :req_options, [])

      case Client.update_message(
             token_ref,
             target,
             provider_message_id,
             %{content: body},
             req_options
           ) do
        {:ok, result} ->
          {:ok,
           %{
             channel: "discord",
             target: target,
             provider_message_id: provider_message_id,
             result: result
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
