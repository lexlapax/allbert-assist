defmodule AllbertAssist.Channels.Telegram.Renderer do
  @moduledoc false

  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Confirmations.ObjectiveContext
  alias AllbertAssist.Runtime.MediaOutputs

  @telegram_limit 4096
  @callback_limit 64

  def render_response(runtime_response, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_text_bytes, @telegram_limit)

    if handoff = response_field(runtime_response, :approval_handoff) do
      render_approval_handoff(handoff, opts)
    else
      text =
        runtime_response
        |> response_field(:message, "")
        |> to_string()
        |> with_media_outputs(runtime_response)

      {:ok, chunks(text, min(max_bytes, @telegram_limit)), nil}
    end
  end

  def render_approval_handoff(handoff_data, opts \\ []) do
    text =
      (ObjectiveContext.lines(handoff_data) ++ ApprovalHandoff.lines(handoff_data))
      |> case do
        [] -> ["Approval required."]
        lines -> lines
      end
      |> Enum.join("\n")

    keyboard =
      if Keyword.get(opts, :render_buttons, true) do
        approval_keyboard(confirmation_id(handoff_data))
      end

    {:ok, chunks(text, @telegram_limit), keyboard}
  end

  defp approval_keyboard(nil), do: nil

  defp approval_keyboard(confirmation_id) do
    actions = [
      {"Approve", "approve"},
      {"Deny", "deny"},
      {"Show", "show"}
    ]

    buttons =
      Enum.flat_map(actions, fn {label, action} ->
        data = "allbert:v1:#{action}:#{confirmation_id}"

        if byte_size(data) <= @callback_limit do
          [[%{"text" => label, "callback_data" => data}]]
        else
          []
        end
      end)

    if buttons == [], do: nil, else: %{"inline_keyboard" => buttons}
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

  defp confirmation_id(handoff_data), do: response_field(handoff_data, :confirmation_id)

  defp with_media_outputs(text, runtime_response) do
    outputs =
      runtime_response
      |> response_field(:media_outputs, [])
      |> MediaOutputs.redacted()

    if outputs == [] do
      text
    else
      text <> "\n\nMedia outputs:\n" <> Enum.map_join(outputs, "\n", &media_output_line/1)
    end
  end

  defp media_output_line(output) do
    kind = response_field(output, :kind, "media")
    mime_type = response_field(output, :mime_type)
    resource_uri = response_field(output, :resource_uri)
    source_action = response_field(output, :source_action)

    [
      "- #{kind}",
      mime_type,
      resource_uri,
      source_action
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp response_field(map, key, default \\ nil)

  defp response_field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp response_field(_map, _key, default), do: default
end
