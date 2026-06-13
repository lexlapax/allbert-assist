defmodule AllbertAssist.Channels.Slack.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.ConfirmationCallback
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.InboundTrust
  alias AllbertAssist.Channels.Slack.Client
  alias AllbertAssist.Channels.Slack.Client.SocketModePort
  alias AllbertAssist.Channels.Slack.Parser
  alias AllbertAssist.Channels.Slack.Renderer
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.Redactor

  @provider "slack_socket_mode"

  # Message subtypes that are echoes of our own / other bots' activity or edits,
  # never fresh user input. Dropping them at admission prevents reply loops that
  # `ChannelThread.echo?` (outbound-ref matching) alone does not cover.
  @echo_subtypes ~w[bot_message message_changed message_deleted]

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  def simulate_socket_envelope(server \\ __MODULE__, envelope) do
    GenServer.call(server, {:simulate_socket_envelope, envelope})
  end

  @impl true
  def init(opts) do
    state =
      opts
      |> load_state()
      |> resolve_bot_identity()
      |> maybe_start_socket_mode()

    {:ok, state}
  end

  @impl true
  def handle_call({:simulate_socket_envelope, envelope}, _from, state) do
    {reply, state} = process_socket_envelope(envelope, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:slack_socket_envelope, envelope}, state) do
    {_reply, state} = process_socket_envelope(envelope, state)
    {:noreply, state}
  end

  defp load_state(opts) do
    settings =
      case Channels.channel_settings("slack") do
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
      bot_token_ref: Map.get(settings, "bot_token_ref", "secret://channels/slack/bot_token"),
      app_token_ref: Map.get(settings, "app_token_ref", "secret://channels/slack/app_token"),
      client_opts: client_opts,
      socket_mode_port_module: Keyword.get(opts, :socket_mode_port, SocketModePort.Real),
      socket_mode_opts: Keyword.get(opts, :socket_mode_opts, []),
      socket_mode_port: nil,
      socket_mode_status: :not_started,
      bot_user_id: nil,
      diagnostics: AllbertSlack.Settings.Fragment.required_when_enabled(settings),
      last_hello: nil
    }
  end

  # Resolve our own bot user id (best-effort, once at startup) so admission can
  # drop the bot's own posts even when Slack omits `bot_id`/`subtype`. A failed
  # or stubbed-out auth.test simply leaves `bot_user_id` nil; the bot_id/subtype
  # echo filters still apply.
  defp resolve_bot_identity(%{enabled?: false} = state), do: state

  defp resolve_bot_identity(state) do
    case Client.auth_test(state.bot_token_ref, state.client_opts) do
      {:ok, %{"user_id" => user_id}} when is_binary(user_id) and user_id != "" ->
        %{state | bot_user_id: user_id}

      _other ->
        state
    end
  end

  defp maybe_start_socket_mode(%{enabled?: false} = state),
    do: %{state | socket_mode_status: :disabled}

  defp maybe_start_socket_mode(%{diagnostics: diagnostics} = state) when diagnostics != [] do
    %{state | socket_mode_status: {:not_started, {:invalid_settings, diagnostics}}}
  end

  defp maybe_start_socket_mode(state) do
    opts =
      [
        owner: self(),
        app_token_ref: state.app_token_ref,
        reconnect_max_backoff_ms:
          Map.get(state.settings, "socket_mode", %{})
          |> Map.get("reconnect_max_backoff_ms", 30_000),
        client_opts: state.client_opts
      ]
      |> Keyword.merge(state.socket_mode_opts)

    case state.socket_mode_port_module.start_link(opts) do
      {:ok, pid} ->
        %{state | socket_mode_port: pid, socket_mode_status: :running}

      {:error, reason} ->
        Logger.debug("slack socket mode not started: #{inspect(Redactor.redact(reason))}")
        %{state | socket_mode_status: {:error, reason}}
    end
  end

  defp process_socket_envelope(envelope, state) do
    case Parser.parse_socket_envelope(envelope) do
      {:hello, fields} ->
        {{:ok, {:hello, fields}}, %{state | last_hello: DateTime.utc_now()}}

      {:message, fields} ->
        case admit_message(fields, state) do
          :admit ->
            {handle_message(fields, state), state}

          {:ignore, reason} ->
            # Not fresh user input for us (provider echo, or excluded by
            # response_style). Drop without persisting a channel_event row so
            # high-volume chatter and bot echoes cannot flood the audit trail or
            # trigger reply loops.
            Logger.debug("slack message ignored (#{reason})")
            {{:ok, :ignored}, state}
        end

      {:interactive, fields} ->
        {handle_interactive(fields, state), state}

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

  defp handle_interactive(fields, state) do
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
      channel: "slack",
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
      channel: "slack",
      provider: @provider,
      direction: "inbound",
      external_event_id: external_event_id,
      status: "rejected",
      reason: to_string(reason),
      payload_summary: "unsupported slack event"
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
        Logger.debug("slack simulated event rejected: #{inspect(Redactor.redact(reason))}")
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
             {:ok, delivered} <- deliver_rendered(fields, rendered, state),
             :ok <- record_outbound_refs(response, fields, delivered),
             {:ok, event} <- mark_processed(event, response, user_id, session_id) do
          {:ok, event, rendered}
        end
    end
  end

  defp process_callback(event, fields, state) do
    with :ok <- validate_callback_allowlist(fields, state),
         {:ok, user_id} <- resolve_identity(fields, state),
         {:ok, inbound_trust} <- authorize_inbound(fields, user_id, :callback),
         session_id <-
           Channels.derive_session_id("slack", fields.external_user_id, fields.external_chat_id),
         {:ok, response} <-
           run_confirmation_callback(fields, state, user_id, session_id, inbound_trust),
         {:ok, rendered} <- render_confirmation_response(response, state),
         {:ok, _delivered} <- deliver_callback_result(fields, rendered, state),
         {:ok, event} <- mark_callback_processed(event, response, user_id, session_id) do
      {:ok, {:processed, event, rendered}}
    else
      {:error, reason} ->
        Logger.debug("slack callback rejected: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  # Decide whether an inbound Slack message event is something we should act on,
  # before any DB write. Two gates: (1) provider echo — the bot's own posts,
  # other bots, and edit/delete tombstones; (2) response_style — `mention`
  # (app_mention + DMs), `always` (also plain channel messages), `dm_only` (DMs
  # only). DMs themselves are still authorized downstream by the identity map.
  defp admit_message(fields, state) do
    cond do
      provider_echo?(fields, state) -> {:ignore, :echo_provider}
      not response_style_admits?(fields, state) -> {:ignore, :response_style}
      true -> :admit
    end
  end

  defp provider_echo?(fields, state) do
    not is_nil(Map.get(fields, :bot_id)) or
      Map.get(fields, :subtype) in @echo_subtypes or
      (is_binary(state.bot_user_id) and fields.external_user_id == state.bot_user_id)
  end

  defp response_style_admits?(fields, state) do
    style = Map.get(state.settings, "response_style", "mention")

    cond do
      dm?(fields) -> style in ["mention", "always", "dm_only"]
      mention?(fields) -> style in ["mention", "always"]
      true -> style == "always"
    end
  end

  defp dm?(fields), do: Map.get(fields, :is_dm?, false)
  defp mention?(fields), do: Map.get(fields, :event_type) == "app_mention"

  defp validate_allowlist(fields, state) do
    workspace_team_id = Map.get(state.settings, "workspace_team_id", "")
    allowed_channel_ids = Map.get(state.settings, "allowed_channel_ids", [])

    cond do
      workspace_team_id not in ["", fields.team_id] ->
        {:error, :team_not_allowed}

      # DMs (channel_type "im") carry an ephemeral `D…` id that is never in the
      # channel allowlist; per ADR 0056 the identity map is their authorization
      # gate (enforced by resolve_identity downstream), so they bypass the
      # channel-id allowlist here while still being team-scoped.
      dm?(fields) ->
        :ok

      fields.channel_id not in allowed_channel_ids ->
        {:error, :channel_not_allowed}

      true ->
        :ok
    end
  end

  defp validate_callback_allowlist(fields, state) do
    workspace_team_id = Map.get(state.settings, "workspace_team_id", "")
    allowed_channel_ids = Map.get(state.settings, "allowed_channel_ids", [])

    cond do
      workspace_team_id not in ["", fields.team_id] ->
        {:error, :team_not_allowed}

      fields.channel_id not in allowed_channel_ids ->
        {:error, :channel_not_allowed}

      true ->
        :ok
    end
  end

  defp validate_text(fields, state) do
    max_text_bytes = Map.get(state.settings, "max_text_bytes", 3000)

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
         channel: "slack",
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
      "slack",
      fields.external_user_id,
      Map.get(state.settings, "identity_map", [])
    )
  end

  defp authorize_inbound(fields, user_id, surface) do
    InboundTrust.authorize(%{
      user_id: user_id,
      channel: "slack",
      provider: @provider,
      surface: "slack_#{surface}",
      external_user_id: fields.external_user_id,
      external_chat_id: fields.external_chat_id,
      receiver_account_ref: Map.get(fields, :receiver_account_ref)
    })
  end

  defp session_id(fields) do
    Channels.derive_session_id("slack", fields.external_user_id, fields.thread_ts)
  end

  defp submit_runtime(fields, user_id, session_id, inbound_trust) do
    Runtime.submit_user_input(%{
      text: fields.text,
      channel: "slack",
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      channel_thread_ref: fields.channel_thread_ref,
      provider_message_id: fields.external_message_id,
      metadata: %{
        channel: "slack",
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

  defp renderer_opts(state) do
    [
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 3000),
      render_buttons: Map.get(state.settings, "render_approval_buttons", true)
    ]
  end

  defp deliver_rendered(fields, rendered, state) do
    rendered
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {payload, index}, {:ok, delivered} ->
      payload =
        payload
        |> Map.put(:channel, fields.channel_id)
        |> Map.put(:thread_ts, fields.thread_ts)

      case Client.chat_post_message(state.bot_token_ref, payload, state.client_opts) do
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
      channel: "slack",
      user_id: user_id,
      identity_proof: identity_proof(fields, state, user_id),
      session_id: session_id,
      surface: "slack_interactive",
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
      channel: "slack",
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
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 3000),
      render_buttons: false
    )
  end

  defp deliver_callback_result(fields, rendered, state) do
    rendered
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {payload, index}, {:ok, delivered} ->
      payload =
        payload
        |> Map.put(:channel, fields.channel_id || fields.external_chat_id)
        |> Map.put(:thread_ts, fields.thread_ts)

      case Client.chat_post_message(state.bot_token_ref, payload, state.client_opts) do
        {:ok, message} ->
          {:cont, {:ok, delivered ++ [%{part_id: to_string(index), message: message}]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp record_outbound_refs(response, fields, delivered) do
    delivered
    |> Enum.reduce_while(:ok, fn delivered_part, :ok ->
      attrs =
        fields.channel_thread_ref
        |> Map.put(:canonical_message_id, response_value(response, :assistant_message_id))
        |> Map.put(:canonical_thread_id, response_value(response, :thread_id))
        |> Map.put(:provider_message_id, Map.get(delivered_part.message, "ts"))
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
               :team_not_allowed,
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
end
