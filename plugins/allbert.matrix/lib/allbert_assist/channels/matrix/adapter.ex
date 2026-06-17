defmodule AllbertAssist.Channels.Matrix.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.Matrix.Client
  alias AllbertAssist.Channels.Matrix.Parser
  alias AllbertAssist.Channels.Matrix.Renderer
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings.Secrets

  @provider "matrix_client_server"
  @max_backoff_ms 60_000
  @poll_once_call_timeout_ms 120_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def poll_once(server \\ __MODULE__, timeout_ms \\ @poll_once_call_timeout_ms),
    do: GenServer.call(server, :poll_once, timeout_ms)

  @impl true
  def init(opts) do
    state = load_state(opts)

    if state.enabled? and Keyword.get(opts, :auto_poll?, true) do
      Process.send_after(self(), :poll, 0)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:poll_once, _from, state) do
    {reply, state} = poll(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    {_reply, state} = poll(state)
    schedule_poll(state)
    {:noreply, state}
  end

  defp load_state(opts) do
    base = %{
      enabled?: false,
      diagnostics: [],
      settings: %{},
      homeserver_url: nil,
      access_token: nil,
      since: nil,
      backoff_ms: 0,
      sync_poll_interval_ms: 2000,
      sync_timeout_ms: 30_000,
      req_options: Keyword.get(opts, :req_options, [])
    }

    with {:ok, settings} <- Channels.channel_settings("matrix"),
         true <- Map.get(settings, "enabled", false),
         {:ok, homeserver_url} <- homeserver_url(settings),
         {:ok, access_token} <- resolve_access_token(settings) do
      %{
        base
        | enabled?: true,
          settings: settings,
          homeserver_url: homeserver_url,
          access_token: access_token,
          sync_poll_interval_ms: Map.get(settings, "sync_poll_interval_ms", 2000),
          sync_timeout_ms: Map.get(settings, "sync_timeout_ms", 30_000)
      }
    else
      false -> %{base | diagnostics: [:disabled]}
      {:error, reason} -> %{base | diagnostics: [reason]}
    end
  end

  defp homeserver_url(settings) do
    case Map.get(settings, "homeserver_url") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_homeserver_url}, else: {:ok, value}

      _value ->
        {:error, :missing_homeserver_url}
    end
  end

  defp resolve_access_token(settings) do
    ref = Map.get(settings, "access_token_ref")

    case Secrets.get_secret(ref) do
      {:ok, token} when is_binary(token) ->
        token = String.trim(token)
        if token == "", do: {:error, :missing_matrix_access_token}, else: {:ok, token}

      _error ->
        {:error, :missing_matrix_access_token}
    end
  end

  defp poll(%{enabled?: false} = state), do: {{:error, :disabled}, state}

  defp poll(%{enabled?: true} = state) do
    case Client.sync(
           state.homeserver_url,
           state.access_token,
           state.since,
           state.sync_timeout_ms,
           state.req_options
         ) do
      {:ok, sync} ->
        {summary, next_since} = process_sync(sync, state)
        {{:ok, summary}, %{state | since: next_since || state.since, backoff_ms: 0}}

      {:error, reason} ->
        Logger.warning("matrix sync failed: #{inspect(redact(reason))}")
        {{:error, reason}, %{state | backoff_ms: next_backoff(state.backoff_ms)}}
    end
  end

  defp process_sync(sync, state) do
    events = Parser.parse_sync(sync)

    summary =
      Enum.reduce(events, %{processed: 0, duplicates: 0, rejected: 0, failed: 0}, fn event,
                                                                                     summary ->
        case process_parsed_event(event, state) do
          {:ok, :processed} -> Map.update!(summary, :processed, &(&1 + 1))
          {:ok, :duplicate} -> Map.update!(summary, :duplicates, &(&1 + 1))
          {:ok, :rejected} -> Map.update!(summary, :rejected, &(&1 + 1))
          {:error, _reason} -> Map.update!(summary, :failed, &(&1 + 1))
        end
      end)

    {summary, Map.get(sync, "next_batch")}
  end

  defp process_parsed_event({:text_message, fields}, state), do: process_text_event(fields, state)
  defp process_parsed_event({:unsupported, fields}, _state), do: insert_rejected_event(fields)
  defp process_parsed_event({:malformed, reason}, _state), do: {:error, {:malformed, reason}}

  defp process_text_event(fields, state) do
    fields = put_thread_fields(fields, state)
    {text, new_thread?} = prompt_text(fields.text)
    fields = maybe_isolate_new_provider_thread(fields, new_thread?)

    case insert_received_event(fields, "inbound") do
      {:ok, %AllbertAssist.Channels.Event{} = event} ->
        handle_text_event(event, fields, text, new_thread?, state)

      {:ok, :duplicate} ->
        {:ok, :duplicate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_text_event(event, fields, text, new_thread?, state) do
    with :ok <- validate_room(fields, state),
         :ok <- validate_text_size(fields, state),
         :ok <- reject_echo(fields),
         {:ok, user_id} <- resolve_identity(fields, state),
         session_id <-
           Channels.derive_session_id("matrix", fields.external_user_id, fields.room_id),
         {:ok, response} <- submit_runtime(text, user_id, session_id, fields, new_thread?),
         {:ok, chunks} <-
           Renderer.render_response(response, max_text_bytes: max_text_bytes(state)),
         {:ok, delivered} <- deliver_chunks(fields.room_id, chunks, state, fields),
         :ok <- record_outbound_refs(response, fields, delivered),
         {:ok, _event} <- mark_processed(event, response, user_id, session_id) do
      {:ok, :processed}
    else
      {:error, {:delivery_failed, _reason} = reason} ->
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:error, reason}

      {:error, reason} ->
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  defp insert_received_event(fields, direction) do
    %{
      channel: "matrix",
      provider: @provider,
      direction: direction,
      external_event_id: fields.external_event_id,
      external_user_id: fields.external_user_id,
      external_chat_id: fields.room_id,
      external_message_id: fields.external_message_id,
      status: "received",
      payload_summary: fields.raw_summary
    }
    |> Channels.create_event()
    |> event_result()
  end

  defp insert_rejected_event(fields) do
    %{
      channel: "matrix",
      provider: @provider,
      direction: "inbound",
      external_event_id:
        Map.get(fields, :external_event_id) || "malformed_#{Ecto.UUID.generate()}",
      external_chat_id: Map.get(fields, :external_chat_id),
      status: "rejected",
      reason: Map.get(fields, :type, "unsupported_event"),
      payload_summary: "unsupported matrix event"
    }
    |> Channels.create_event()
    |> event_result(:rejected)
  end

  defp validate_room(fields, state) do
    allowed = Map.get(state.settings, "allowed_room_ids", [])

    if fields.room_id in allowed do
      :ok
    else
      {:error, :room_not_allowed}
    end
  end

  defp validate_text_size(fields, state) do
    if byte_size(fields.text) <= max_text_bytes(state) do
      :ok
    else
      {:error, :oversized}
    end
  end

  defp reject_echo(fields) do
    if ChannelThread.echo?(%{
         channel: "matrix",
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
      "matrix",
      fields.external_user_id,
      Map.get(state.settings, "identity_map", [])
    )
  end

  defp prompt_text("/new " <> text), do: {String.trim(text), true}
  defp prompt_text(text), do: {text, false}

  defp put_thread_fields(fields, state) do
    receiver_account_ref = matrix_receiver_account_ref(fields, state)
    provider_thread_ref = matrix_provider_thread_ref(fields)

    fields
    |> Map.put(:receiver_account_ref, receiver_account_ref)
    |> Map.put(:provider_thread_ref, provider_thread_ref)
    |> Map.put(:channel_thread_ref, channel_thread_ref(receiver_account_ref, provider_thread_ref))
    |> Map.put(:known_thread_id, known_thread_id_from_relation(receiver_account_ref, fields))
  end

  defp maybe_isolate_new_provider_thread(fields, true) do
    provider_thread_ref =
      matrix_provider_thread_ref(%{fields | thread_root_event_id: fields.external_message_id})

    fields
    |> Map.put(:provider_thread_ref, provider_thread_ref)
    |> Map.put(
      :channel_thread_ref,
      channel_thread_ref(fields.receiver_account_ref, provider_thread_ref)
    )
    |> Map.delete(:known_thread_id)
  end

  defp maybe_isolate_new_provider_thread(fields, _new_thread?), do: fields

  defp matrix_receiver_account_ref(fields, state) do
    homeserver_ref =
      state.settings
      |> Map.get("homeserver_url", state.homeserver_url)
      |> ChannelThread.provider_thread_key()

    "matrix:homeserver:#{homeserver_ref}:room:#{fields.room_id}"
  end

  defp matrix_provider_thread_ref(fields) do
    %{
      provider: "matrix",
      room_id: fields.room_id,
      provider_thread_root:
        fields.thread_root_event_id || fields.reply_to_event_id || fields.external_message_id,
      thread_root_event_id: fields.thread_root_event_id || fields.external_message_id,
      reply_to_event_id: fields.reply_to_event_id
    }
    |> compact()
  end

  defp channel_thread_ref(receiver_account_ref, provider_thread_ref) do
    %{
      channel: "matrix",
      receiver_account_ref: receiver_account_ref,
      provider_thread_ref: provider_thread_ref
    }
  end

  defp known_thread_id_from_relation(receiver_account_ref, fields) do
    [fields.thread_root_event_id, fields.reply_to_event_id]
    |> Enum.find_value(fn event_id ->
      if is_binary(event_id) and event_id != "" do
        case ChannelThread.lookup_message_thread(%{
               channel: "matrix",
               receiver_account_ref: receiver_account_ref,
               provider_message_id: event_id
             }) do
          {:ok, thread_id} -> thread_id
          {:error, _reason} -> nil
        end
      end
    end)
  end

  defp submit_runtime(text, user_id, session_id, fields, new_thread?) do
    %{
      text: text,
      channel: "matrix",
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      new_thread: new_thread?,
      channel_thread_ref: fields.channel_thread_ref,
      provider_message_id: fields.external_message_id,
      metadata: %{
        channel: "matrix",
        provider: @provider,
        external_event_id: fields.external_event_id,
        external_user_id: fields.external_user_id,
        external_chat_id: fields.room_id,
        external_message_id: fields.external_message_id,
        receiver_account_ref: fields.receiver_account_ref,
        provider_thread_ref: fields.provider_thread_ref,
        thread_root_event_id: fields.thread_root_event_id,
        reply_to_event_id: fields.reply_to_event_id
      }
    }
    |> maybe_put_known_thread_id(fields, new_thread?)
    |> Runtime.submit_user_input()
  end

  defp maybe_put_known_thread_id(attrs, fields, false) do
    case Map.get(fields, :known_thread_id) do
      thread_id when is_binary(thread_id) and thread_id != "" ->
        Map.put(attrs, :thread_id, thread_id)

      _thread_id ->
        attrs
    end
  end

  defp maybe_put_known_thread_id(attrs, _fields, _new_thread?), do: attrs

  defp deliver_chunks(room_id, chunks, state, fields) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {chunk, index}, {:ok, delivered} ->
      content = Renderer.message_content(chunk, matrix_reply_fields(fields))
      txn_id = Ecto.UUID.generate()

      case Client.send_message(
             state.homeserver_url,
             state.access_token,
             room_id,
             txn_id,
             content,
             state.req_options
           ) do
        {:ok, %{"event_id" => event_id} = message} ->
          delivered_part = %{
            part_id: to_string(index),
            event_id: event_id,
            txn_id: txn_id,
            message: message,
            content: content
          }

          {:cont, {:ok, delivered ++ [delivered_part]}}

        {:ok, body} ->
          {:halt, {:error, {:delivery_failed, {:missing_event_id, body}}}}

        {:error, reason} ->
          {:halt, {:error, {:delivery_failed, reason}}}
      end
    end)
  end

  defp matrix_reply_fields(fields) do
    %{
      thread_root_event_id: fields.thread_root_event_id || fields.external_message_id,
      reply_to_event_id: fields.external_message_id,
      external_message_id: fields.external_message_id
    }
  end

  defp record_outbound_refs(response, fields, delivered) do
    delivered
    |> Enum.reduce_while(:ok, fn delivered_part, :ok ->
      attrs =
        fields.channel_thread_ref
        |> Map.put(:canonical_message_id, response_value(response, :assistant_message_id))
        |> Map.put(:canonical_thread_id, response_value(response, :thread_id))
        |> Map.put(:provider_message_id, delivered_part.event_id)
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

  defp mark_rejected_or_failed(event, {:delivery_failed, reason}) do
    Channels.update_event(event, %{status: "failed", error: inspect(redact(reason))})
  end

  defp mark_rejected_or_failed(event, reason) do
    Channels.update_event(event, %{status: "rejected", reason: inspect(reason)})
  end

  defp event_result(result, inserted_status \\ :processed)

  defp event_result({:ok, event}, :processed), do: {:ok, event}
  defp event_result({:ok, _event}, inserted_status), do: {:ok, inserted_status}

  defp event_result({:error, %Ecto.Changeset{} = changeset}, _inserted_status) do
    if duplicate_event?(changeset) do
      case Channels.received_event_from_duplicate(changeset, "matrix") do
        %AllbertAssist.Channels.Event{} = event -> {:ok, event}
        nil -> {:ok, :duplicate}
      end
    else
      {:error, changeset}
    end
  end

  defp duplicate_event?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique
    end)
  end

  defp max_text_bytes(state), do: Map.get(state.settings, "max_text_bytes", 4000)

  defp compact(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp next_backoff(0), do: 1000
  defp next_backoff(backoff_ms), do: min(backoff_ms * 2, @max_backoff_ms)

  defp schedule_poll(%{enabled?: false}), do: :ok

  defp schedule_poll(state) do
    delay = if state.backoff_ms > 0, do: state.backoff_ms, else: state.sync_poll_interval_ms
    Process.send_after(self(), :poll, delay)
    :ok
  end

  defp redact({:matrix_error, status, body}), do: {:matrix_error, status, body}
  defp redact({:transport_error, reason}), do: {:transport_error, reason}
  defp redact(reason), do: reason
end
