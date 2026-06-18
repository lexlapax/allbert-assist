defmodule AllbertAssist.Channels.Matrix.Parser do
  @moduledoc false

  def parse_sync(%{"rooms" => %{"join" => rooms}}) when is_map(rooms) do
    rooms
    |> Enum.flat_map(fn {room_id, room} -> parse_room(room_id, room) end)
  end

  def parse_sync(_sync), do: []

  def parse_messages(room_id, %{"chunk" => events}) when is_list(events) do
    Enum.map(events, &parse_event(room_id, &1))
  end

  def parse_messages(_room_id, _messages), do: []

  def simulated_message_event(attrs) when is_map(attrs) do
    %{
      "event_id" => Map.fetch!(attrs, :event_id),
      "sender" => Map.fetch!(attrs, :sender),
      "type" => "m.room.message",
      "origin_server_ts" => Map.get(attrs, :origin_server_ts, 1_781_477_600_000),
      "content" =>
        %{
          "msgtype" => "m.text",
          "body" => Map.fetch!(attrs, :text)
        }
        |> maybe_put_relates_to(attrs)
    }
  end

  defp parse_room(room_id, %{"timeline" => %{"events" => events}}) when is_list(events) do
    Enum.map(events, &parse_event(room_id, &1))
  end

  defp parse_room(_room_id, _room), do: []

  defp parse_event(room_id, %{
         "event_id" => event_id,
         "sender" => sender,
         "type" => "m.room.message",
         "content" => %{"msgtype" => "m.text", "body" => body} = content
       })
       when is_binary(event_id) and is_binary(sender) and is_binary(body) do
    {:text_message,
     %{
       external_event_id: event_id,
       external_user_id: sender,
       external_chat_id: room_id,
       external_message_id: event_id,
       room_id: room_id,
       sender: sender,
       text: body,
       thread_root_event_id: thread_root_event_id(content),
       reply_to_event_id: reply_to_event_id(content),
       raw_summary: "matrix text message #{event_id}"
     }}
  end

  defp parse_event(room_id, %{"event_id" => event_id, "type" => "m.room.encrypted"}) do
    {:unsupported,
     %{
       external_event_id: to_string(event_id),
       external_chat_id: room_id,
       type: "encrypted_not_supported"
     }}
  end

  defp parse_event(room_id, %{"event_id" => event_id, "type" => type}) do
    {:unsupported,
     %{
       external_event_id: to_string(event_id),
       external_chat_id: room_id,
       type: to_string(type || "unsupported_event")
     }}
  end

  defp parse_event(_room_id, _event), do: {:malformed, :missing_event_fields}

  defp maybe_put_relates_to(content, attrs) do
    root = Map.get(attrs, :thread_root_event_id)
    reply_to = Map.get(attrs, :reply_to_event_id)

    cond do
      is_binary(root) and root != "" and is_binary(reply_to) and reply_to != "" ->
        Map.put(content, "m.relates_to", %{
          "rel_type" => "m.thread",
          "event_id" => root,
          "m.in_reply_to" => %{"event_id" => reply_to},
          "is_falling_back" => true
        })

      is_binary(root) and root != "" ->
        Map.put(content, "m.relates_to", %{"rel_type" => "m.thread", "event_id" => root})

      is_binary(reply_to) and reply_to != "" ->
        Map.put(content, "m.relates_to", %{"m.in_reply_to" => %{"event_id" => reply_to}})

      true ->
        content
    end
  end

  defp thread_root_event_id(content) do
    case Map.get(content, "m.relates_to") do
      %{"rel_type" => "m.thread", "event_id" => event_id} when is_binary(event_id) -> event_id
      _relates_to -> nil
    end
  end

  defp reply_to_event_id(content) do
    case Map.get(content, "m.relates_to") do
      %{"m.in_reply_to" => %{"event_id" => event_id}} when is_binary(event_id) -> event_id
      _relates_to -> nil
    end
  end
end
