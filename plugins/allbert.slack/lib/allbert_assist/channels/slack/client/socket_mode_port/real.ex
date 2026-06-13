defmodule AllbertAssist.Channels.Slack.Client.SocketModePort.Real do
  @moduledoc false

  use WebSockex

  require Logger

  alias AllbertAssist.Channels.Slack.Client
  alias AllbertAssist.Runtime.Redactor

  @behaviour AllbertAssist.Channels.Slack.Client.SocketModePort

  @default_app_token_ref "secret://channels/slack/app_token"

  @impl true
  def start_link(opts) do
    app_token_ref = Keyword.get(opts, :app_token_ref, @default_app_token_ref)
    client_opts = opts |> Keyword.get(:client_opts, []) |> Keyword.put_new(:mode, :real)

    with {:ok, socket_url} <- socket_url(app_token_ref, client_opts, opts) do
      state = %{
        owner: Keyword.get(opts, :owner),
        reconnect_max_backoff_ms: Keyword.get(opts, :reconnect_max_backoff_ms, 30_000),
        graceful_reconnect?: false
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

      websocket_module.start_link(socket_url, __MODULE__, state, websocket_opts)
    end
  end

  @impl true
  def push(server, envelope), do: WebSockex.cast(server, {:push, envelope})

  @impl true
  def ack(server, envelope_id, payload \\ nil) do
    WebSockex.cast(server, {:ack, envelope_id, payload})
  end

  @impl true
  def handle_connect(_conn, state), do: {:ok, state}

  @impl true
  def handle_frame({:text, frame}, state) do
    case Jason.decode(frame) do
      {:ok, %{"type" => "hello"} = envelope} ->
        dispatch(envelope, state)
        {:ok, state}

      {:ok, %{"type" => "disconnect"} = envelope} ->
        # Slack proactively asks the client to reconnect (reason "warning" /
        # "refresh_requested" / "too_many_connections"). Close and let
        # handle_disconnect reopen — WITHOUT dispatching the frame to the adapter
        # (otherwise it is persisted as a spurious rejected event). Mark the
        # reconnect graceful so handle_disconnect skips the error backoff sleep.
        Logger.debug(
          "slack socket mode disconnect frame: #{inspect(Redactor.redact(Map.get(envelope, "reason")))}"
        )

        {:close, %{state | graceful_reconnect?: true}}

      {:ok, %{"envelope_id" => envelope_id} = envelope} when is_binary(envelope_id) ->
        send(self(), {:slack_socket_dispatch_after_ack, envelope})
        {:reply, {:text, Jason.encode!(ack_payload(envelope_id, nil))}, state}

      {:ok, envelope} when is_map(envelope) ->
        dispatch(envelope, state)
        {:ok, state}

      {:error, _reason} ->
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:push, envelope}, state) when is_map(envelope) do
    {:reply, {:text, Jason.encode!(envelope)}, state}
  end

  def handle_cast({:ack, envelope_id, payload}, state) when is_binary(envelope_id) do
    {:reply, {:text, Jason.encode!(ack_payload(envelope_id, payload))}, state}
  end

  def handle_cast(_message, state), do: {:ok, state}

  @impl true
  def handle_info({:slack_socket_dispatch_after_ack, envelope}, state) when is_map(envelope) do
    dispatch(envelope, state)
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, %{graceful_reconnect?: true} = state) do
    # Server-requested reconnect: reopen promptly with no backoff sleep, so the
    # WebSockex callback never blocks on a graceful connection rotation.
    Logger.debug("slack socket mode reconnecting (graceful): #{inspect(Redactor.redact(reason))}")
    {:reconnect, %{state | graceful_reconnect?: false}}
  end

  def handle_disconnect(%{attempt_number: attempt, reason: reason}, state) do
    backoff = backoff(attempt, state.reconnect_max_backoff_ms)
    Logger.debug("slack socket mode disconnected: #{inspect(Redactor.redact(reason))}")
    Process.sleep(backoff)
    {:reconnect, state}
  end

  defp socket_url(app_token_ref, client_opts, opts) do
    case Keyword.get(opts, :socket_mode_url) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _missing -> fetch_socket_url(app_token_ref, client_opts)
    end
  end

  defp fetch_socket_url(app_token_ref, client_opts) do
    case Client.apps_connections_open(app_token_ref, client_opts) do
      {:ok, %{"url" => url}} when is_binary(url) and url != "" -> {:ok, url}
      {:ok, _body} -> {:error, :slack_socket_mode_url_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(envelope, state) do
    if is_pid(state.owner), do: send(state.owner, {:slack_socket_envelope, envelope})
  end

  defp ack_payload(envelope_id, nil), do: %{"envelope_id" => envelope_id}

  defp ack_payload(envelope_id, payload),
    do: %{"envelope_id" => envelope_id, "payload" => payload}

  defp backoff(attempt, max_backoff) when is_integer(attempt) and attempt > 0 do
    min(max_backoff, attempt * 250)
  end

  defp backoff(_attempt, max_backoff), do: min(max_backoff, 250)
end
