defmodule AllbertAssist.Channels.Slack.Renderer do
  @moduledoc false

  alias AllbertAssist.Approval.Handoff
  alias AllbertAssist.Runtime.MediaOutputs

  @slack_limit 3000

  def render_response(runtime_response, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_text_bytes, @slack_limit) |> min(@slack_limit)

    if handoff = response_field(runtime_response, :approval_handoff) do
      render_approval_handoff(handoff, opts)
    else
      text =
        runtime_response
        |> response_field(:message, "")
        |> to_string()
        |> with_media_outputs(runtime_response)

      {:ok, chunks(text, max_bytes)}
    end
  end

  def render_approval_handoff(handoff_data, opts \\ []) do
    descriptor = effective_descriptor(opts)

    with {:ok, {primitive, payload}} <- Handoff.render(handoff_data, descriptor) do
      {:ok, [approval_message(primitive, payload)]}
    end
  end

  defp effective_descriptor(opts) do
    primitives =
      if Keyword.get(opts, :render_buttons, true) do
        [:button, :typed_command, :list]
      else
        [:typed_command, :list]
      end

    %{primitives: primitives, threading: :native_threads}
  end

  defp approval_message(:button, %{text: text, buttons: buttons}) do
    %{
      text: text,
      blocks: [
        %{type: "section", text: %{type: "mrkdwn", text: text}},
        %{
          type: "actions",
          elements:
            Enum.map(buttons, fn button ->
              %{
                type: "button",
                text: %{type: "plain_text", text: Map.get(button, :label), emoji: true},
                action_id: Map.get(button, :callback_data),
                value: Map.get(button, :callback_data),
                style: button_style(Map.get(button, :action))
              }
            end)
        }
      ]
    }
  end

  defp approval_message(_primitive, %{text: text}), do: %{text: text}

  defp chunks("", _limit), do: [%{text: ""}]

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
    |> Enum.map(&%{text: &1})
  end

  defp button_style(:approve), do: "primary"
  defp button_style(:deny), do: "danger"
  defp button_style(_action), do: nil

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
