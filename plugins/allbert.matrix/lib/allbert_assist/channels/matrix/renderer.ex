defmodule AllbertAssist.Channels.Matrix.Renderer do
  @moduledoc false

  alias AllbertAssist.Approval.Handoff

  @default_limit 4000

  def render_response(runtime_response, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_text_bytes, @default_limit)

    text =
      if handoff = response_field(runtime_response, :approval_handoff) do
        render_approval_handoff(handoff)
      else
        runtime_response
        |> response_field(:message, "")
        |> to_string()
      end

    {:ok, chunks(text, max_bytes)}
  end

  def message_content(text, fields \\ %{}) do
    %{
      "msgtype" => "m.text",
      "body" => text
    }
    |> maybe_put_relation(fields)
  end

  defp render_approval_handoff(handoff_data) do
    descriptor = %{primitives: [:typed_command, :link, :list], threading: :native_threads}

    with {:ok, {primitive, payload}} <- Handoff.render(handoff_data, descriptor) do
      case primitive do
        :typed_command -> typed_command_text(payload)
        :link -> link_text(payload)
        :list -> numbered_options_text(payload)
        _primitive -> response_field(payload, :text, "Approval required.")
      end
    else
      _error -> "Approval required."
    end
  end

  defp typed_command_text(%{text: text, commands: commands}) when is_list(commands) do
    [
      text,
      "",
      "Reply with one exact command:",
      Enum.map_join(commands, "\n", &"- #{&1}")
    ]
    |> Enum.join("\n")
  end

  defp typed_command_text(%{text: text}), do: text

  defp link_text(%{text: text, url: url}) do
    [text, "", "Open approval:", url]
    |> Enum.join("\n")
  end

  defp link_text(%{text: text}), do: text

  defp numbered_options_text(%{text: text, numbered_options: options}) when is_list(options) do
    [
      text,
      "",
      "Reply with one option command:",
      Enum.map_join(options, "\n", fn option ->
        "#{Map.get(option, :index)}. #{Map.get(option, :label)} - #{Map.get(option, :command)}"
      end)
    ]
    |> Enum.join("\n")
  end

  defp numbered_options_text(%{text: text}), do: text

  defp maybe_put_relation(content, fields) do
    root = Map.get(fields, :thread_root_event_id)
    reply_to = Map.get(fields, :reply_to_event_id) || Map.get(fields, :external_message_id)

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

  defp chunks("", _limit), do: [""]

  defp chunks(text, limit) do
    text
    |> String.graphemes()
    |> Enum.reduce({[], "", 0}, fn grapheme, {chunks, current, current_bytes} ->
      grapheme_bytes = byte_size(grapheme)

      if current != "" and current_bytes + grapheme_bytes > limit do
        {[current | chunks], grapheme, grapheme_bytes}
      else
        {chunks, current <> grapheme, current_bytes + grapheme_bytes}
      end
    end)
    |> then(fn {chunks, current, _bytes} -> Enum.reverse([current | chunks]) end)
  end

  defp response_field(map, key, default \\ nil)

  defp response_field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp response_field(_map, _key, default), do: default
end
