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
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime.Paths, as: RuntimePaths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  @provider "telegram_bot_api"
  @max_backoff_ms 60_000
  @telegram_file_download_max_bytes 20 * 1024 * 1024
  @telegram_voice_extensions ~w[.ogg .oga .mp3 .m4a .wav .webm]
  @callback_data_re ~r/\Aallbert:v1:(approve|deny|show):([A-Za-z0-9_-]+)\z/
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
        process_text_update(fields, state)

      {:voice_message, fields} ->
        process_voice_update(fields, state)

      {:callback_query, fields} ->
        process_callback_update(fields, state)

      {:unsupported, %{external_event_id: external_event_id, type: type}} ->
        insert_rejected_event(external_event_id, type)

      {:malformed, reason} ->
        {:error, {:malformed, reason}}
    end
  end

  defp process_text_update(fields, state) do
    case insert_received_event(fields, "inbound") do
      {:ok, %AllbertAssist.Channels.Event{} = event} -> handle_text_message(event, fields, state)
      {:ok, :duplicate} -> {:ok, :duplicate}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_voice_update(fields, state) do
    case insert_received_event(fields, "inbound") do
      {:ok, %AllbertAssist.Channels.Event{} = event} -> handle_voice_message(event, fields, state)
      {:ok, :duplicate} -> {:ok, :duplicate}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_callback_update(fields, state) do
    case insert_received_event(fields, "callback") do
      {:ok, %AllbertAssist.Channels.Event{} = event} -> handle_callback(event, fields, state)
      {:ok, :duplicate} -> {:ok, :duplicate}
      {:error, reason} -> {:error, reason}
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
    fields = put_thread_fields(fields, state)
    {text, new_thread?} = prompt_text(fields.text)
    fields = maybe_isolate_new_provider_thread(fields, new_thread?)

    with :ok <- validate_chat(fields, state),
         :ok <- validate_text_size(fields, state),
         :ok <- reject_echo(fields),
         {:ok, user_id} <- resolve_identity(fields, state),
         session_id <-
           Channels.derive_session_id(
             "telegram",
             fields.external_user_id,
             fields.external_chat_id
           ),
         {:ok, response} <- submit_runtime(text, user_id, session_id, fields, new_thread?),
         {:ok, chunks, keyboard} <- render_response(response, state),
         {:ok, delivered} <-
           Runtime.track_delivery(response, %{channel: "telegram"}, fn ->
             deliver_chunks(fields.external_chat_id, chunks, keyboard, state, fields)
           end),
         :ok <- record_outbound_refs(response, fields, delivered),
         :ok <- Runtime.acknowledge_deliveries(response, %{channel: "telegram"}),
         {:ok, _event} <- mark_processed(event, response, user_id, session_id) do
      {:ok, :processed}
    else
      {:error, reason} ->
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  defp handle_voice_message(event, fields, state) do
    fields = put_thread_fields(fields, state)

    with :ok <- validate_chat(fields, state),
         :ok <- validate_voice_size(fields),
         :ok <- reject_echo(fields),
         {:ok, user_id} <- resolve_identity(fields, state),
         session_id <-
           Channels.derive_session_id(
             "telegram",
             fields.external_user_id,
             fields.external_chat_id
           ),
         {:ok, audio} <- fetch_voice_audio(fields, state) do
      result =
        with {:ok, transcription} <- transcribe_voice_audio(audio, user_id, session_id, fields),
             :ok <- validate_transcript_size(transcription.transcript, state),
             {:ok, response} <-
               submit_runtime(
                 transcription.transcript,
                 user_id,
                 session_id,
                 fields,
                 false,
                 voice_runtime_metadata(fields, audio, transcription)
               ),
             {:ok, chunks, keyboard} <- render_response(response, state),
             {:ok, delivered} <-
               Runtime.track_delivery(response, %{channel: "telegram"}, fn ->
                 deliver_chunks(fields.external_chat_id, chunks, keyboard, state, fields)
               end),
             :ok <- record_outbound_refs(response, fields, delivered),
             :ok <- Runtime.acknowledge_deliveries(response, %{channel: "telegram"}),
             {:ok, _event} <- mark_processed(event, response, user_id, session_id) do
          {:ok, :processed}
        end

      cleanup_voice_audio(audio)

      case result do
        {:ok, :processed} ->
          {:ok, :processed}

        {:error, reason} ->
          {:ok, _event} = mark_rejected_or_failed(event, reason)
          {:ok, :rejected}
      end
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

  defp validate_transcript_size(text, state) when is_binary(text) do
    max_text_bytes = Map.get(state.settings, "max_text_bytes", 4096)

    if byte_size(text) <= max_text_bytes do
      :ok
    else
      {:error, :oversized}
    end
  end

  defp validate_voice_size(fields) do
    max_bytes = voice_download_max_bytes()

    case Map.get(fields, :voice_file_size) do
      size when is_integer(size) and size > max_bytes ->
        {:error, {:telegram_voice_too_large, size, max_bytes}}

      _size ->
        :ok
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

  defp put_thread_fields(fields, state) do
    receiver_account_ref = telegram_receiver_account_ref(fields, state)
    provider_thread_ref = telegram_provider_thread_ref(fields)

    fields
    |> Map.put(:receiver_account_ref, receiver_account_ref)
    |> Map.put(:provider_thread_ref, provider_thread_ref)
    |> Map.put(:channel_thread_ref, channel_thread_ref(receiver_account_ref, provider_thread_ref))
    |> Map.put(:known_thread_id, known_thread_id_from_reply(receiver_account_ref, fields))
  end

  defp maybe_isolate_new_provider_thread(fields, true) do
    provider_thread_ref =
      telegram_provider_thread_ref(fields, "message:#{fields.external_message_id}")

    fields
    |> Map.put(:provider_thread_ref, provider_thread_ref)
    |> Map.put(
      :channel_thread_ref,
      channel_thread_ref(fields.receiver_account_ref, provider_thread_ref)
    )
    |> Map.delete(:known_thread_id)
  end

  defp maybe_isolate_new_provider_thread(fields, _new_thread?), do: fields

  defp reject_echo(fields) do
    if ChannelThread.echo?(%{
         channel: "telegram",
         receiver_account_ref: fields.receiver_account_ref,
         provider_message_id: fields.external_message_id
       }) do
      {:error, :echo_suppressed}
    else
      :ok
    end
  end

  defp telegram_receiver_account_ref(fields, state) do
    bot_ref =
      state.settings
      |> Map.get("bot_token_ref", "secret://channels/telegram/bot_token")
      |> ChannelThread.provider_thread_key()

    "telegram:bot:#{bot_ref}:chat:#{fields.external_chat_id}"
  end

  defp telegram_provider_thread_ref(fields, provider_thread_root \\ nil) do
    %{
      provider: "telegram",
      chat_id: fields.external_chat_id,
      chat_type: Map.get(fields, :chat_type),
      message_thread_id: Map.get(fields, :message_thread_id),
      provider_thread_root: provider_thread_root || telegram_provider_thread_root(fields),
      reply_to_message_id: Map.get(fields, :reply_to_message_id)
    }
    |> compact()
  end

  defp telegram_provider_thread_root(%{message_thread_id: message_thread_id} = fields)
       when is_binary(message_thread_id) and message_thread_id != "" do
    "topic:#{message_thread_id}:user:#{fields.external_user_id}"
  end

  defp telegram_provider_thread_root(%{reply_to_message_id: reply_to_message_id})
       when is_binary(reply_to_message_id) and reply_to_message_id != "" do
    "reply:#{reply_to_message_id}"
  end

  defp telegram_provider_thread_root(fields), do: "message:#{fields.external_message_id}"

  defp channel_thread_ref(receiver_account_ref, provider_thread_ref) do
    %{
      channel: "telegram",
      receiver_account_ref: receiver_account_ref,
      provider_thread_ref: provider_thread_ref
    }
  end

  defp known_thread_id_from_reply(receiver_account_ref, %{
         reply_to_message_id: reply_to_message_id
       })
       when is_binary(reply_to_message_id) and reply_to_message_id != "" do
    case ChannelThread.lookup_message_thread(%{
           channel: "telegram",
           receiver_account_ref: receiver_account_ref,
           provider_message_id: reply_to_message_id
         }) do
      {:ok, thread_id} -> thread_id
      {:error, _reason} -> nil
    end
  end

  defp known_thread_id_from_reply(_receiver_account_ref, _fields), do: nil

  defp compact(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end

  defp submit_runtime(text, user_id, session_id, fields, new_thread?) do
    submit_runtime(text, user_id, session_id, fields, new_thread?, %{})
  end

  defp submit_runtime(text, user_id, session_id, fields, new_thread?, extra_metadata) do
    %{
      text: text,
      channel: "telegram",
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      new_thread: new_thread?,
      channel_thread_ref: fields.channel_thread_ref,
      provider_message_id: fields.external_message_id,
      metadata:
        %{
          channel: "telegram",
          provider: @provider,
          external_event_id: fields.external_event_id,
          external_user_id: fields.external_user_id,
          external_chat_id: fields.external_chat_id,
          external_message_id: fields.external_message_id,
          receiver_account_ref: fields.receiver_account_ref,
          provider_thread_ref: fields.provider_thread_ref,
          message_thread_id: Map.get(fields, :message_thread_id),
          reply_to_message_id: Map.get(fields, :reply_to_message_id)
        }
        |> Map.merge(extra_metadata)
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

  defp fetch_voice_audio(fields, state) do
    max_bytes = voice_download_max_bytes()
    req_options = Keyword.put(state.req_options, :max_response_bytes, max_bytes)

    with {:ok, file} <- Client.get_file(state.token, fields.voice_file_id, state.req_options),
         {:ok, file_path} <- telegram_file_path(file),
         :ok <- validate_telegram_file_size(file, max_bytes),
         {:ok, body} <- Client.download_file(state.token, file_path, req_options),
         :ok <- validate_downloaded_voice(body, max_bytes),
         {:ok, path} <- store_voice_audio(fields, file_path, body) do
      {:ok,
       %{
         path: path,
         byte_size: byte_size(body),
         file_size: Map.get(file, "file_size"),
         mime_type: fields.voice_mime_type
       }}
    end
  end

  defp telegram_file_path(%{"file_path" => file_path}) when is_binary(file_path) do
    file_path = String.trim(file_path)
    if file_path == "", do: {:error, :missing_telegram_file_path}, else: {:ok, file_path}
  end

  defp telegram_file_path(_file), do: {:error, :missing_telegram_file_path}

  defp validate_telegram_file_size(file, max_bytes) do
    case Map.get(file, "file_size") do
      size when is_integer(size) and size > max_bytes ->
        {:error, {:telegram_voice_too_large, size, max_bytes}}

      _size ->
        :ok
    end
  end

  defp validate_downloaded_voice(body, max_bytes) when is_binary(body) do
    size = byte_size(body)

    cond do
      size == 0 ->
        {:error, :empty_telegram_voice}

      size > max_bytes ->
        {:error, {:telegram_voice_too_large, size, max_bytes}}

      true ->
        :ok
    end
  end

  defp voice_download_max_bytes do
    case Settings.get("voice.audio.max_bytes") do
      {:ok, value} when is_integer(value) and value > 0 ->
        min(value, @telegram_file_download_max_bytes)

      _error ->
        @telegram_file_download_max_bytes
    end
  end

  defp store_voice_audio(fields, file_path, body) do
    with {:ok, extension} <- voice_extension(file_path, fields),
         {:ok, destination} <- voice_destination(fields, extension),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.write(destination, body) do
      {:ok, destination}
    end
  end

  defp voice_extension(file_path, fields) do
    extension =
      file_path
      |> Path.extname()
      |> String.downcase()
      |> case do
        "" -> extension_from_mime(Map.get(fields, :voice_mime_type))
        extension -> extension
      end

    if extension in @telegram_voice_extensions do
      {:ok, extension}
    else
      {:error, {:unsupported_telegram_voice_type, extension}}
    end
  end

  defp extension_from_mime("audio/ogg"), do: ".ogg"
  defp extension_from_mime("audio/opus"), do: ".ogg"
  defp extension_from_mime("audio/mpeg"), do: ".mp3"
  defp extension_from_mime("audio/mp4"), do: ".m4a"
  defp extension_from_mime("audio/wav"), do: ".wav"
  defp extension_from_mime("audio/webm"), do: ".webm"
  defp extension_from_mime(_mime_type), do: ".ogg"

  defp voice_destination(fields, extension) do
    event_id =
      fields.external_event_id
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

    {:ok,
     Path.join([
       RuntimePaths.tmp_root(),
       "telegram-voice",
       event_id,
       "telegram-voice-#{event_id}#{extension}"
     ])}
  end

  defp transcribe_voice_audio(audio, user_id, session_id, fields) do
    case Runner.run(
           "transcribe_voice",
           %{audio_file: audio.path},
           %{
             actor: user_id,
             channel: "telegram",
             surface: "telegram_voice_note",
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
               external_message_id: fields.external_message_id
             }
           }
         ) do
      {:ok, %{status: :completed, transcript: transcript, voice_metadata: metadata}}
      when is_binary(transcript) ->
        {:ok, %{transcript: transcript, voice_metadata: Redactor.redact_audio_metadata(metadata)}}

      {:ok, %{status: status} = response} ->
        {:error, {:voice_transcription_failed, status, Map.get(response, :error)}}
    end
  end

  defp voice_runtime_metadata(fields, audio, transcription) do
    %{
      voice: transcription.voice_metadata,
      telegram_voice: %{
        file_id: fields.voice_file_id,
        file_unique_id: fields.voice_file_unique_id,
        duration_seconds: fields.voice_duration_seconds,
        mime_type: fields.voice_mime_type,
        file_size: fields.voice_file_size || audio.file_size,
        downloaded_byte_size: audio.byte_size,
        source: "telegram_voice_note",
        redaction_status: "redacted"
      }
    }
  end

  defp cleanup_voice_audio(%{path: path}) do
    _ = File.rm(path)
    _ = File.rmdir(Path.dirname(path))
    :ok
  end

  defp render_response(response, state) do
    Renderer.render_response(response,
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 4096),
      render_buttons: Map.get(state.settings, "render_approval_buttons", true)
    )
  end

  defp deliver_chunks(chat_id, chunks, keyboard, state, fields) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {chunk, index}, {:ok, delivered} ->
      keyboard = if index == 0, do: keyboard, else: nil

      opts =
        state.req_options
        |> Keyword.merge(reply_markup: keyboard)
        |> maybe_put_reply_options(fields)

      case Client.send_message(state.token, chat_id, chunk, opts) do
        {:ok, message} ->
          {:cont, {:ok, delivered ++ [%{part_id: to_string(index), message: message}]}}

        {:error, reason} ->
          {:halt, {:error, {:delivery_failed, reason}}}
      end
    end)
  end

  defp maybe_put_reply_options(opts, fields) do
    opts
    |> maybe_put_keyword(:reply_to_message_id, Map.get(fields, :external_message_id))
    |> maybe_put_keyword(:message_thread_id, Map.get(fields, :message_thread_id))
  end

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, _key, ""), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp record_outbound_refs(response, fields, delivered) do
    delivered
    |> Enum.reduce_while(:ok, fn delivered_part, :ok ->
      attrs =
        fields.channel_thread_ref
        |> Map.put(:canonical_message_id, response_value(response, :assistant_message_id))
        |> Map.put(:canonical_thread_id, response_value(response, :thread_id))
        |> Map.put(:provider_message_id, Map.get(delivered_part.message, "message_id"))
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

  defp parse_callback_data(data) when is_binary(data) do
    if byte_size(data) <= 64 do
      case Regex.run(@callback_data_re, data) do
        [_, action, confirmation_id] -> {:ok, action, confirmation_id}
        _match -> {:error, :malformed_callback_data}
      end
    else
      {:error, :callback_data_too_long}
    end
  end

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

  defp deliver_callback_result(chat_id, chunks, state) do
    case deliver_chunks(chat_id, chunks, nil, state, %{external_message_id: nil}) do
      {:ok, _delivered} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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
    if duplicate_event?(changeset) do
      case Channels.received_event_from_duplicate(changeset, "telegram") do
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

  # v0.54 M10 (ADR 0063): outbound compose boundary callback. Sends `body` to
  # `target` (a chat id) via the bot token resolved from channel settings.
  @doc false
  def deliver_outbound(target, body, _opts) when is_binary(target) and is_binary(body) do
    with {:ok, settings} <- AllbertAssist.Channels.channel_settings("telegram"),
         {:ok, token} <- resolve_token(settings),
         {:ok, result} <- Client.send_message(token, target, body, []) do
      {:ok, %{channel: "telegram", target: target, result: result}}
    end
  end
end
