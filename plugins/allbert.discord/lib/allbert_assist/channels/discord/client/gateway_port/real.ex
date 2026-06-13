defmodule AllbertAssist.Channels.Discord.Client.GatewayPort.Real do
  @moduledoc false

  use WebSockex

  import Bitwise

  require Logger

  alias AllbertAssist.Channels.Discord.Client
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings.Secrets

  @behaviour AllbertAssist.Channels.Discord.Client.GatewayPort

  @default_token_ref "secret://channels/discord/bot_token"
  @gateway_query "v=10&encoding=json"
  @interaction_deferred_update_message 6
  @default_intents ["guilds", "guild_messages", "direct_messages", "message_content"]
  @intent_bits %{
    "guilds" => 1 <<< 0,
    "guild_messages" => 1 <<< 9,
    "direct_messages" => 1 <<< 12,
    "message_content" => 1 <<< 15
  }

  @impl true
  def start_link(opts) do
    token_ref = Keyword.get(opts, :token_ref, @default_token_ref)
    client_opts = opts |> Keyword.get(:client_opts, []) |> Keyword.put_new(:mode, :real)

    with {:ok, token} <- resolve_token(token_ref),
         {:ok, gateway_url} <- gateway_url(token_ref, client_opts, opts) do
      state = %{
        owner: Keyword.get(opts, :owner),
        token: token,
        client_opts: client_opts,
        intents: intents(Keyword.get(opts, :intents, @default_intents)),
        conn: nil,
        sequence: nil,
        session_id: nil,
        resume?: false,
        heartbeat_interval_ms: nil,
        last_heartbeat_acked?: true,
        heartbeat_jitter?: Keyword.get(opts, :heartbeat_jitter?, true),
        reconnect_max_backoff_ms: Keyword.get(opts, :reconnect_max_backoff_ms, 30_000)
      }

      websocket_module = Keyword.get(opts, :websocket_module, WebSockex)

      websocket_opts =
        [
          async: true,
          handle_initial_conn_failure: true,
          socket_connect_timeout: Keyword.get(opts, :socket_connect_timeout, 10_000),
          socket_recv_timeout: Keyword.get(opts, :socket_recv_timeout, 10_000)
        ]
        |> Keyword.merge(Keyword.get(opts, :websocket_opts, []))

      websocket_module.start_link(gateway_url, __MODULE__, state, websocket_opts)
    end
  end

  @impl true
  def push(server, event), do: WebSockex.cast(server, {:push, event})

  @impl true
  def handle_connect(conn, state), do: {:ok, %{state | conn: conn}}

  @impl true
  def handle_frame({:text, frame}, state) do
    case Jason.decode(frame) do
      {:ok, payload} -> handle_gateway_payload(payload, state)
      {:error, _reason} -> {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:push, event}, state) when is_map(event) do
    {:reply, {:text, Jason.encode!(event)}, state}
  end

  def handle_cast(_message, state), do: {:ok, state}

  @impl true
  def handle_info(
        :heartbeat,
        %{heartbeat_interval_ms: interval, last_heartbeat_acked?: true} = state
      )
      when is_integer(interval) and interval > 0 do
    schedule_heartbeat(interval)

    {:reply, {:text, Jason.encode!(%{"op" => 1, "d" => state.sequence})},
     %{state | last_heartbeat_acked?: false}}
  end

  def handle_info(
        :heartbeat,
        %{heartbeat_interval_ms: interval, last_heartbeat_acked?: false} = state
      )
      when is_integer(interval) and interval > 0 do
    # The previous heartbeat (op 1) was never acknowledged (op 11): the connection
    # is zombied. Force-close and reconnect via the RESUME path rather than
    # heartbeating into a dead socket.
    Logger.debug("discord gateway heartbeat not acknowledged; forcing reconnect")
    {:ok, close_gateway_socket(mark_resumable(state))}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{attempt_number: attempt, reason: reason}, state) do
    backoff = backoff(attempt, state.reconnect_max_backoff_ms)
    Logger.debug("discord gateway disconnected: #{inspect(Redactor.redact(reason))}")
    Process.sleep(backoff)
    {:reconnect, mark_resumable(state)}
  end

  defp handle_gateway_payload(%{"op" => 10, "d" => %{"heartbeat_interval" => interval}}, state)
       when is_integer(interval) do
    schedule_heartbeat(initial_heartbeat_delay(interval, state.heartbeat_jitter?))

    state = %{state | heartbeat_interval_ms: interval, last_heartbeat_acked?: true}
    payload = hello_payload(state)

    {:reply, {:text, Jason.encode!(payload)}, %{state | resume?: false}}
  end

  defp handle_gateway_payload(
         %{"op" => 0, "t" => "INTERACTION_CREATE", "s" => sequence, "d" => data} = payload,
         state
       ) do
    # The interaction acknowledgement is a Discord transport-protocol obligation
    # (it must reach `POST /interactions/{id}/{token}/callback` within 3s, over
    # REST). Owning it here — symmetric with the Slack SocketModePort acking the
    # envelope_id (M8R3) — keeps it off the adapter's serial mailbox, so a slow
    # message turn can never delay it. The adapter handles the business callback.
    acknowledge_interaction(data, state)

    state =
      state
      |> Map.put(:sequence, sequence)
      |> maybe_store_session("INTERACTION_CREATE", data)

    if is_pid(state.owner), do: send(state.owner, {:discord_gateway_event, payload})
    {:ok, state}
  end

  defp handle_gateway_payload(
         %{"op" => 0, "t" => type, "s" => sequence, "d" => data} = payload,
         state
       ) do
    state =
      state
      |> Map.put(:sequence, sequence)
      |> maybe_store_session(type, data)

    if is_pid(state.owner), do: send(state.owner, {:discord_gateway_event, payload})
    {:ok, state}
  end

  defp handle_gateway_payload(%{"op" => 11}, state),
    do: {:ok, %{state | last_heartbeat_acked?: true}}

  defp handle_gateway_payload(%{"op" => 7}, state),
    do: reconnect_via_disconnect(mark_resumable(state))

  defp handle_gateway_payload(%{"op" => 9, "d" => true}, state),
    do: reconnect_via_disconnect(mark_resumable(state))

  defp handle_gateway_payload(%{"op" => 9}, state),
    do: reconnect_via_disconnect(clear_session(state))

  defp handle_gateway_payload(_payload, state), do: {:ok, state}

  defp maybe_store_session(state, "READY", %{"session_id" => session_id})
       when is_binary(session_id),
       do: %{state | session_id: session_id, resume?: false}

  defp maybe_store_session(state, "RESUMED", _data), do: %{state | resume?: false}

  defp maybe_store_session(state, _type, _data), do: state

  defp hello_payload(%{resume?: true, session_id: session_id, sequence: sequence} = state)
       when is_binary(session_id) and is_integer(sequence) do
    %{
      "op" => 6,
      "d" => %{
        "token" => state.token,
        "session_id" => session_id,
        "seq" => sequence
      }
    }
  end

  defp hello_payload(state) do
    %{
      "op" => 2,
      "d" => %{
        "token" => state.token,
        "intents" => state.intents,
        "properties" => %{
          "os" => "allbert",
          "browser" => "allbert",
          "device" => "allbert"
        }
      }
    }
  end

  defp mark_resumable(%{session_id: session_id, sequence: sequence} = state)
       when is_binary(session_id) and is_integer(sequence),
       do: %{state | resume?: true}

  defp mark_resumable(state), do: state

  defp clear_session(state), do: %{state | session_id: nil, sequence: nil, resume?: false}

  defp reconnect_via_disconnect(state) do
    {:ok, close_gateway_socket(state)}
  end

  defp close_gateway_socket(%{conn: %WebSockex.Conn{socket: nil}} = state), do: state

  defp close_gateway_socket(%{conn: %WebSockex.Conn{} = conn} = state) do
    socket = conn.socket
    transport = conn.transport
    closed_conn = WebSockex.Conn.close_socket(conn)

    queue_socket_closed(transport, socket)

    %{state | conn: closed_conn}
  end

  defp close_gateway_socket(state), do: state

  defp queue_socket_closed(:tcp, socket) when not is_nil(socket),
    do: send(self(), {:tcp_closed, socket})

  defp queue_socket_closed(:ssl, socket) when not is_nil(socket),
    do: send(self(), {:ssl_closed, socket})

  defp queue_socket_closed(_transport, _socket), do: :ok

  defp resolve_token(token_ref) when is_binary(token_ref) do
    case Secrets.get_secret(token_ref) do
      {:ok, token} when is_binary(token) ->
        token = String.trim(token)

        if token == "" do
          {:error, :missing_discord_token}
        else
          {:ok, token}
        end

      {:ok, _token} ->
        {:error, :missing_discord_token}

      {:error, reason} ->
        {:error, {:discord_token_unavailable, reason}}
    end
  end

  defp resolve_token(_token_ref), do: {:error, :invalid_discord_token_ref}

  defp gateway_url(token_ref, client_opts, opts) do
    case Keyword.get(opts, :gateway_url) do
      url when is_binary(url) and url != "" -> {:ok, normalize_gateway_url(url)}
      _missing -> fetch_gateway_url(token_ref, client_opts)
    end
  end

  defp fetch_gateway_url(token_ref, client_opts) do
    case Client.gateway_bot(token_ref, client_opts) do
      {:ok, %{"url" => url}} when is_binary(url) and url != "" ->
        {:ok, normalize_gateway_url(url)}

      {:ok, _body} ->
        {:error, :discord_gateway_url_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_gateway_url(url) do
    uri = URI.parse(url)

    query =
      [uri.query, @gateway_query]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("&")

    %{uri | query: query}
    |> URI.to_string()
  end

  defp acknowledge_interaction(%{"id" => id, "token" => token}, state)
       when is_binary(id) and is_binary(token) and token != "" do
    client_opts = state.client_opts

    # Fire the deferred ack off the socket process (REST POST, not a WS reply) so
    # it never blocks the gateway's heartbeat/receive loop. Best-effort: a failed
    # ack is logged (redacted), not retried — the 3s window has already passed.
    Task.start(fn ->
      case Client.interaction_callback(
             id,
             token,
             %{type: @interaction_deferred_update_message},
             client_opts
           ) do
        {:ok, _response} ->
          :ok

        {:error, reason} ->
          Logger.debug("discord interaction ack failed: #{inspect(Redactor.redact(reason))}")
      end
    end)

    :ok
  end

  defp acknowledge_interaction(_data, _state), do: :ok

  defp intents(names) when is_list(names) do
    {known, unknown} = Enum.split_with(names, &Map.has_key?(@intent_bits, to_string(&1)))

    unless unknown == [] do
      Logger.warning(
        "discord gateway ignoring unknown intent name(s): #{inspect(unknown)} " <>
          "(known: #{inspect(Map.keys(@intent_bits))})"
      )
    end

    Enum.reduce(known, 0, fn name, acc -> acc ||| Map.fetch!(@intent_bits, to_string(name)) end)
  end

  defp intents(value) when is_integer(value), do: value
  defp intents(_value), do: intents(@default_intents)

  defp schedule_heartbeat(delay) when is_integer(delay) and delay > 0 do
    Process.send_after(self(), :heartbeat, delay)
  end

  defp initial_heartbeat_delay(interval, true), do: max(1, div(interval, 2))
  defp initial_heartbeat_delay(interval, _jitter?), do: interval

  defp backoff(attempt, max_backoff) when is_integer(attempt) and attempt > 0 do
    min(max_backoff, attempt * 250)
  end

  defp backoff(_attempt, max_backoff), do: min(max_backoff, 250)
end
