defmodule AllbertAssist.Channels.Slack.Renderer do
  @moduledoc false

  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  @slack_limit 3000
  @descriptor %{
    primitives: [:button, :typed_command, :list],
    threading: :native_threads,
    payload: :message,
    media_outputs: true
  }

  def render_response(runtime_response, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_text_bytes, @slack_limit) |> min(@slack_limit)
    descriptor = effective_descriptor(opts)

    with {:ok, rendered} <-
           SurfaceRenderer.render_response(runtime_response, descriptor,
             max_text_bytes: max_bytes
           ) do
      case rendered.kind do
        :approval_handoff -> {:ok, [approval_message(rendered.primitive, rendered.payload)]}
        _kind -> {:ok, text_messages(rendered.chunks, runtime_response, opts)}
      end
    end
  end

  def render_approval_handoff(handoff_data, opts \\ []) do
    with {:ok, rendered} <-
           SurfaceRenderer.render_approval_handoff(handoff_data, effective_descriptor(opts)) do
      {:ok, [approval_message(rendered.primitive, rendered.payload)]}
    end
  end

  defp effective_descriptor(opts) do
    primitives =
      if Keyword.get(opts, :render_buttons, true) do
        [:button, :typed_command, :list]
      else
        [:typed_command, :list]
      end

    Map.put(@descriptor, :primitives, primitives)
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
                value: Map.get(button, :callback_data)
              }
              # Slack rejects `"style": null` ("invalid_blocks"); only set style
              # for approve/deny and omit it entirely for other buttons (e.g.
              # "show"/details).
              |> maybe_put_style(button_style(Map.get(button, :action)))
            end)
        }
      ]
    }
  end

  defp approval_message(:typed_command, %{text: text, commands: commands}) do
    %{text: text <> "\n" <> Enum.join(commands, "\n")}
  end

  defp approval_message(_primitive, %{text: text}), do: %{text: text}

  defp text_messages(chunks, response, opts) do
    chunks
    |> Enum.map(&%{text: &1})
    |> maybe_add_notify_offer(response, opts)
  end

  defp maybe_add_notify_offer([first | rest], response, opts) do
    if response_field(response, :notify_offer) && Keyword.get(opts, :render_buttons, true) do
      blocks = [
        %{type: "section", text: %{type: "mrkdwn", text: first.text}},
        %{
          type: "actions",
          elements: [
            %{
              type: "button",
              style: "primary",
              text: %{type: "plain_text", text: "Enable notifications", emoji: true},
              action_id: "ALLBERT:NOTIFY:ON",
              value: "ALLBERT:NOTIFY:ON"
            }
          ]
        }
      ]

      [Map.put(first, :blocks, blocks) | rest]
    else
      [first | rest]
    end
  end

  defp maybe_add_notify_offer(messages, _response, _opts), do: messages

  defp response_field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp button_style(:approve), do: "primary"
  defp button_style(:deny), do: "danger"
  defp button_style(_action), do: nil

  defp maybe_put_style(button, nil), do: button
  defp maybe_put_style(button, style), do: Map.put(button, :style, style)
end
