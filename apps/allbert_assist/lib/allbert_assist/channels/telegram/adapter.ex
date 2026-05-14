defmodule AllbertAssist.Channels.Telegram.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.Telegram.Client
  alias AllbertAssist.Channels.Telegram.Parser
  alias AllbertAssist.Channels.Telegram.Renderer
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings.Secrets

  @provider "telegram_bot_api"
  @max_backoff_ms 60_000
  @callback_data_re ~r/\Aallbert:v1:(approve|deny|show):([A-Za-z0-9_-]+)\z/

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def poll_once(server \\ __MODULE__), do: GenServer.call(server, :poll_once)

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
      token: nil,
      settings: %{},
      offset: 0,
      backoff_ms: 0,
      poll_interval_ms: 2000,
      poll_timeout_seconds: 25,
      req_options: Keyword.get(opts, :req_options, [])
    }

    with {:ok, settings} <- Channels.channel_settings("telegram"),
         true <- Map.get(settings, "enabled", false),
         {:ok, token} <- resolve_token(settings) do
      %{
        base
        | enabled?: true,
          token: token,
          settings: settings,
          offset: Channels.max_inbound_integer_event_id("telegram") + 1,
          poll_interval_ms: Map.get(settings, "poll_interval_ms", 2000),
          poll_timeout_seconds: Map.get(settings, "poll_timeout_seconds", 25)
      }
    else
      false -> %{base | diagnostics: [:disabled]}
      {:error, reason} -> %{base | diagnostics: [reason]}
    end
  end

  defp resolve_token(settings) do
    ref = Map.get(settings, "bot_token_ref")

    case Secrets.get_secret(ref) do
      {:ok, token} when is_binary(token) and token != "" -> {:ok, token}
      {:ok, _token} -> {:error, :missing_bot_token}
      {:error, _reason} -> {:error, :missing_bot_token}
    end
  end

  defp poll(%{enabled?: false} = state), do: {{:error, :disabled}, state}

  defp poll(%{enabled?: true} = state) do
    case Client.get_updates(
           state.token,
           state.offset,
           state.poll_timeout_seconds,
           state.req_options
         ) do
      {:ok, updates} when is_list(updates) ->
        {summary, offset} = process_updates(updates, state, state.offset)
        {{:ok, summary}, %{state | offset: offset, backoff_ms: 0}}

      {:error, reason} ->
        Logger.warning("telegram poll failed: #{inspect(redact(reason))}")
        {{:error, reason}, %{state | backoff_ms: next_backoff(state.backoff_ms)}}
    end
  end

  defp process_updates(updates, state, offset) do
    Enum.reduce(
      updates,
      {%{processed: 0, duplicates: 0, rejected: 0, failed: 0}, offset},
      fn update, {summary, offset} ->
        next_offset = max(offset, update_id(update) + 1)

        case process_update(update, state) do
          {:ok, :processed} -> {Map.update!(summary, :processed, &(&1 + 1)), next_offset}
          {:ok, :duplicate} -> {Map.update!(summary, :duplicates, &(&1 + 1)), next_offset}
          {:ok, :rejected} -> {Map.update!(summary, :rejected, &(&1 + 1)), next_offset}
          {:error, _reason} -> {Map.update!(summary, :failed, &(&1 + 1)), next_offset}
        end
      end
    )
  end

  defp process_update(update, state) do
    case Parser.parse_update(update) do
      {:text_message, fields} ->
        case insert_received_event(fields, "inbound") do
          {:ok, %AllbertAssist.Channels.Event{} = event} ->
            handle_text_message(event, fields, state)

          {:ok, :duplicate} ->
            {:ok, :duplicate}

          {:error, reason} ->
            {:error, reason}
        end

      {:callback_query, fields} ->
        case insert_received_event(fields, "callback") do
          {:ok, %AllbertAssist.Channels.Event{} = event} -> handle_callback(event, fields, state)
          {:ok, :duplicate} -> {:ok, :duplicate}
          {:error, reason} -> {:error, reason}
        end

      {:unsupported, %{external_event_id: external_event_id, type: type}} ->
        insert_rejected_event(external_event_id, type)

      {:malformed, reason} ->
        {:error, {:malformed, reason}}
    end
  end

  defp insert_received_event(fields, direction) do
    %{
      channel: "telegram",
      provider: @provider,
      direction: direction,
      external_event_id: fields.external_event_id,
      external_user_id: Map.get(fields, :external_user_id),
      external_chat_id: Map.get(fields, :external_chat_id),
      external_message_id: Map.get(fields, :external_message_id),
      status: "received",
      payload_summary: Map.get(fields, :raw_summary)
    }
    |> Channels.create_event()
    |> event_result()
  end

  defp insert_rejected_event(external_event_id, reason) do
    %{
      channel: "telegram",
      provider: @provider,
      direction: "inbound",
      external_event_id: external_event_id,
      status: "rejected",
      reason: reason,
      payload_summary: "unsupported telegram update"
    }
    |> Channels.create_event()
    |> event_result(:rejected)
  end

  defp handle_text_message(event, fields, state) do
    with :ok <- validate_chat(fields, state),
         :ok <- validate_text_size(fields, state),
         {:ok, user_id} <- resolve_identity(fields, state),
         session_id <-
           Channels.derive_session_id(
             "telegram",
             fields.external_user_id,
             fields.external_chat_id
           ),
         {text, new_thread?} <- prompt_text(fields.text),
         {:ok, response} <- submit_runtime(text, user_id, session_id, fields, new_thread?),
         {:ok, chunks, keyboard} <- render_response(response, state),
         :ok <- deliver_chunks(fields.external_chat_id, chunks, keyboard, state),
         {:ok, _event} <- mark_processed(event, response, user_id, session_id) do
      {:ok, :processed}
    else
      {:error, reason} ->
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  defp validate_chat(fields, state) do
    group? = Map.get(fields, :chat_type) in ["group", "supergroup"]
    allowed_chat_ids = Map.get(state.settings, "allowed_chat_ids", [])

    cond do
      not group? ->
        :ok

      Map.get(state.settings, "allow_group_chats", false) and
          fields.external_chat_id in allowed_chat_ids ->
        :ok

      true ->
        {:error, :group_chat_not_allowed}
    end
  end

  defp validate_text_size(fields, state) do
    max_text_bytes = Map.get(state.settings, "max_text_bytes", 4096)

    if byte_size(fields.text) <= max_text_bytes do
      :ok
    else
      {:error, :oversized}
    end
  end

  defp resolve_identity(fields, state) do
    Identity.resolve(
      "telegram",
      fields.external_user_id,
      Map.get(state.settings, "identity_map", [])
    )
  end

  defp prompt_text("/new " <> text), do: {String.trim(text), true}
  defp prompt_text(text), do: {text, false}

  defp submit_runtime(text, user_id, session_id, fields, new_thread?) do
    Runtime.submit_user_input(%{
      text: text,
      channel: "telegram",
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      new_thread: new_thread?,
      metadata: %{
        channel: "telegram",
        provider: @provider,
        external_event_id: fields.external_event_id,
        external_user_id: fields.external_user_id,
        external_chat_id: fields.external_chat_id,
        external_message_id: fields.external_message_id
      }
    })
  end

  defp render_response(response, state) do
    Renderer.render_response(response,
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 4096),
      render_buttons: Map.get(state.settings, "render_approval_buttons", true)
    )
  end

  defp deliver_chunks(_chat_id, [], _keyboard, _state), do: :ok

  defp deliver_chunks(chat_id, [chunk], keyboard, state) do
    case Client.send_message(
           state.token,
           chat_id,
           chunk,
           Keyword.merge(state.req_options, reply_markup: keyboard)
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:delivery_failed, reason}}
    end
  end

  defp deliver_chunks(chat_id, [chunk | rest], keyboard, state) do
    with :ok <- deliver_chunks(chat_id, [chunk], keyboard, state) do
      deliver_chunks(chat_id, rest, nil, state)
    end
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

  defp handle_callback(event, fields, state) do
    with :ok <- callbacks_enabled(state),
         {:ok, action, confirmation_id} <- parse_callback_data(fields.callback_data),
         {:ok, user_id} <- resolve_identity(fields, state),
         session_id <-
           Channels.derive_session_id(
             "telegram",
             fields.external_user_id,
             fields.external_chat_id
           ),
         {:ok, response} <-
           run_confirmation_action(action, confirmation_id, user_id, session_id, fields),
         {:ok, chunks, _keyboard} <- render_confirmation_response(response, state),
         :ok <- deliver_callback_result(fields.external_chat_id, chunks, state),
         {:ok, _event} <- mark_callback_processed(event, response, user_id, session_id) do
      _ack_result = answer_callback(fields.callback_query_id, confirmation_reply(response), state)
      {:ok, :processed}
    else
      {:error, reason} ->
        _ack_result =
          answer_callback(fields.callback_query_id, callback_error_text(reason), state)

        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  defp callbacks_enabled(state) do
    if Map.get(state.settings, "allow_confirmation_callbacks", true) do
      :ok
    else
      {:error, :confirmation_callbacks_disabled}
    end
  end

  defp parse_callback_data(data) when is_binary(data) and byte_size(data) <= 64 do
    case Regex.run(@callback_data_re, data) do
      [_, action, confirmation_id] -> {:ok, action, confirmation_id}
      _match -> {:error, :malformed_callback_data}
    end
  end

  defp parse_callback_data(data) when is_binary(data), do: {:error, :callback_data_too_long}
  defp parse_callback_data(_data), do: {:error, :malformed_callback_data}

  defp run_confirmation_action(action, confirmation_id, user_id, session_id, fields) do
    Runner.run(confirmation_action_name(action), %{id: confirmation_id}, %{
      actor: user_id,
      channel: "telegram",
      surface: "telegram_callback",
      session_id: session_id,
      request: %{
        user_id: user_id,
        operator_id: user_id,
        channel: "telegram",
        session_id: session_id
      },
      resolver_metadata: %{
        provider: @provider,
        external_event_id: fields.external_event_id,
        external_user_id: fields.external_user_id,
        external_chat_id: fields.external_chat_id,
        callback_query_id: fields.callback_query_id
      }
    })
  end

  defp confirmation_action_name("approve"), do: "approve_confirmation"
  defp confirmation_action_name("deny"), do: "deny_confirmation"
  defp confirmation_action_name("show"), do: "show_confirmation"

  defp render_confirmation_response(response, state) do
    Renderer.render_response(%{message: confirmation_reply(response)},
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 4096),
      render_buttons: false
    )
  end

  defp deliver_callback_result(nil, _chunks, _state), do: :ok

  defp deliver_callback_result(chat_id, chunks, state),
    do: deliver_chunks(chat_id, chunks, nil, state)

  defp answer_callback(nil, _message, _state), do: :ok

  defp answer_callback(callback_query_id, message, state) do
    case Client.answer_callback_query(state.token, callback_query_id, message, state.req_options) do
      {:ok, true} -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:callback_ack_failed, reason}}
    end
  end

  defp mark_callback_processed(event, response, user_id, session_id) do
    runner_metadata = response_value(response, :runner_metadata) || %{}

    Channels.update_event(event, %{
      status: "processed",
      user_id: user_id,
      session_id: session_id,
      input_signal_id: response_value(runner_metadata, :requested_signal_id)
    })
  end

  defp confirmation_reply(%{message: message}) when is_binary(message), do: message
  defp confirmation_reply(%{"message" => message}) when is_binary(message), do: message

  defp confirmation_reply(%{confirmation: %{"id" => id, "status" => status}}) do
    "Confirmation #{id}: #{status}."
  end

  defp confirmation_reply(%{"confirmation" => %{"id" => id, "status" => status}}) do
    "Confirmation #{id}: #{status}."
  end

  defp confirmation_reply(response), do: inspect(response, pretty: true)

  defp callback_error_text(:not_mapped), do: "This Telegram account is not connected."
  defp callback_error_text(:disabled), do: "This Telegram account is disabled."
  defp callback_error_text(:malformed_callback_data), do: "Unsupported confirmation button."
  defp callback_error_text(_reason), do: "Could not resolve confirmation."

  defp event_result(result, inserted_status \\ :processed)

  defp event_result({:ok, event}, :processed), do: {:ok, event}
  defp event_result({:ok, _event}, inserted_status), do: {:ok, inserted_status}

  defp event_result({:error, %Ecto.Changeset{} = changeset}, _inserted_status) do
    if duplicate_event?(changeset), do: {:ok, :duplicate}, else: {:error, changeset}
  end

  defp duplicate_event?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique
    end)
  end

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp update_id(%{"update_id" => update_id}) when is_integer(update_id), do: update_id

  defp update_id(%{"update_id" => update_id}) do
    case Integer.parse(to_string(update_id)) do
      {integer, ""} -> integer
      _other -> 0
    end
  end

  defp update_id(_update), do: 0

  defp next_backoff(0), do: 1000
  defp next_backoff(backoff_ms), do: min(backoff_ms * 2, @max_backoff_ms)

  defp schedule_poll(%{enabled?: false}), do: :ok

  defp schedule_poll(state) do
    delay = if state.backoff_ms > 0, do: state.backoff_ms, else: state.poll_interval_ms
    Process.send_after(self(), :poll, delay)
    :ok
  end

  defp redact({:telegram_error, status, body}), do: {:telegram_error, status, body}
  defp redact({:transport_error, reason}), do: {:transport_error, reason}
  defp redact(reason), do: reason
end
