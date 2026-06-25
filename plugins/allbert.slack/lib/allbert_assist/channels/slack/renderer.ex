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
        _kind -> {:ok, Enum.map(rendered.chunks, &%{text: &1})}
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

  defp button_style(:approve), do: "primary"
  defp button_style(:deny), do: "danger"
  defp button_style(_action), do: nil

  defp maybe_put_style(button, nil), do: button
  defp maybe_put_style(button, style), do: Map.put(button, :style, style)
end
