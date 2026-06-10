defmodule AllbertAssist.Channels.Telegram.Parser do
  @moduledoc false

  def parse_update(%{"update_id" => update_id, "message" => %{"text" => text} = message})
      when is_binary(text) do
    with {:ok, from_id} <- from_id(message),
         {:ok, chat_id} <- chat_id(message),
         {:ok, message_id} <- message_id(message) do
      {:text_message,
       %{
         external_event_id: to_string(update_id),
         external_user_id: from_id,
         external_chat_id: chat_id,
         external_message_id: message_id,
         message_thread_id: optional_string(Map.get(message, "message_thread_id")),
         reply_to_message_id: reply_to_message_id(message),
         chat_type: get_in(message, ["chat", "type"]),
         text: text,
         raw_summary: "telegram text message #{message_id}"
       }}
    else
      {:error, reason} -> {:malformed, reason}
    end
  end

  def parse_update(%{"update_id" => update_id, "message" => %{"voice" => voice} = message})
      when is_map(voice) do
    with {:ok, from_id} <- from_id(message),
         {:ok, chat_id} <- chat_id(message),
         {:ok, message_id} <- message_id(message),
         {:ok, file_id} <- voice_file_id(voice) do
      {:voice_message,
       %{
         external_event_id: to_string(update_id),
         external_user_id: from_id,
         external_chat_id: chat_id,
         external_message_id: message_id,
         message_thread_id: optional_string(Map.get(message, "message_thread_id")),
         reply_to_message_id: reply_to_message_id(message),
         chat_type: get_in(message, ["chat", "type"]),
         voice_file_id: file_id,
         voice_file_unique_id: Map.get(voice, "file_unique_id"),
         voice_duration_seconds: Map.get(voice, "duration"),
         voice_mime_type: Map.get(voice, "mime_type"),
         voice_file_size: Map.get(voice, "file_size"),
         raw_summary: "telegram voice message #{message_id}"
       }}
    else
      {:error, reason} -> {:malformed, reason}
    end
  end

  def parse_update(%{"update_id" => update_id, "callback_query" => callback}) do
    with {:ok, callback_id} <- callback_id(callback),
         {:ok, from_id} <- from_id(callback),
         {:ok, data} <- callback_data(callback),
         {:ok, chat_id} <- callback_chat_id(callback) do
      {:callback_query,
       %{
         external_event_id: to_string(update_id),
         external_user_id: from_id,
         external_chat_id: chat_id,
         external_message_id: callback_id,
         callback_query_id: callback_id,
         callback_data: data,
         raw_summary: "telegram callback #{callback_id}"
       }}
    else
      {:error, reason} -> {:malformed, reason}
    end
  end

  def parse_update(%{"update_id" => update_id, "message" => message}) when is_map(message) do
    {:unsupported,
     %{external_event_id: to_string(update_id), type: unsupported_message_type(message)}}
  end

  def parse_update(%{"update_id" => update_id}) do
    {:unsupported, %{external_event_id: to_string(update_id), type: "unknown_update"}}
  end

  def parse_update(_update), do: {:malformed, "missing update_id"}

  defp from_id(%{"from" => %{"id" => id}}), do: {:ok, to_string(id)}
  defp from_id(_map), do: {:error, "missing from.id"}

  defp chat_id(%{"chat" => %{"id" => id}}), do: {:ok, to_string(id)}
  defp chat_id(_message), do: {:error, "missing chat.id"}

  defp message_id(%{"message_id" => id}), do: {:ok, to_string(id)}
  defp message_id(_message), do: {:error, "missing message_id"}

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  defp reply_to_message_id(%{"reply_to_message" => %{"message_id" => id}}), do: to_string(id)
  defp reply_to_message_id(_message), do: nil

  defp voice_file_id(%{"file_id" => file_id}) when is_binary(file_id) and file_id != "",
    do: {:ok, file_id}

  defp voice_file_id(_voice), do: {:error, "missing voice.file_id"}

  defp callback_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp callback_id(_callback), do: {:error, "missing callback id"}

  defp callback_data(%{"data" => data}) when is_binary(data), do: {:ok, data}
  defp callback_data(_callback), do: {:error, "missing callback data"}

  defp callback_chat_id(%{"message" => %{"chat" => %{"id" => id}}}), do: {:ok, to_string(id)}
  defp callback_chat_id(_callback), do: {:ok, nil}

  defp unsupported_message_type(message) do
    cond do
      Map.has_key?(message, "document") -> "document"
      Map.has_key?(message, "photo") -> "photo"
      Map.has_key?(message, "voice") -> "voice"
      Map.has_key?(message, "sticker") -> "sticker"
      true -> "unsupported_message"
    end
  end
end
