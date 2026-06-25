defmodule AllbertAssist.Channels.WhatsApp.Renderer do
  @moduledoc false

  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  @default_limit 4096
  @button_title_limit 20
  @button_id_limit 256
  @descriptor %{
    primitives: [:button, :typed_command, :link, :list],
    threading: :reply_chain,
    payload: :message
  }

  def render_response(runtime_response, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_text_bytes, @default_limit) |> min(@default_limit)
    descriptor = effective_descriptor(opts)

    with {:ok, rendered} <-
           SurfaceRenderer.render_response(runtime_response, descriptor,
             max_text_bytes: max_bytes
           ) do
      case rendered.kind do
        :approval_handoff -> {:ok, [approval_message(rendered.primitive, rendered.payload)]}
        _kind -> {:ok, Enum.map(rendered.chunks, &%{type: :text, body: &1})}
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
        [:button, :typed_command, :link, :list]
      else
        [:typed_command, :link, :list]
      end

    Map.put(@descriptor, :primitives, primitives)
  end

  defp approval_message(:button, %{text: text, buttons: buttons}) do
    sanitized =
      buttons
      |> Enum.take(3)
      |> Enum.map(fn button ->
        %{
          id: button |> Map.get(:callback_data) |> bounded(@button_id_limit),
          title: button |> Map.get(:label) |> bounded(@button_title_limit)
        }
      end)

    %{
      type: :interactive_buttons,
      body: bounded(text, @default_limit),
      buttons: sanitized
    }
  end

  defp approval_message(:typed_command, %{text: text, commands: commands}) do
    %{
      type: :text,
      body:
        Enum.join([text, "", "Reply with one exact command:", Enum.join(commands, "\n")], "\n")
    }
  end

  defp approval_message(:link, %{text: text, url: url}) do
    %{type: :text, body: Enum.join([text, "", "Open approval:", url], "\n")}
  end

  defp approval_message(:list, %{text: text, numbered_options: options}) do
    body =
      [
        text,
        "",
        "Reply with one option command:",
        Enum.map_join(options, "\n", fn option ->
          "#{Map.get(option, :index)}. #{Map.get(option, :label)} - #{Map.get(option, :command)}"
        end)
      ]
      |> Enum.join("\n")

    %{type: :text, body: body}
  end

  defp approval_message(_primitive, %{text: text}), do: %{type: :text, body: text}

  defp bounded(value, limit) do
    SurfaceRenderer.bound_text(to_string(value), limit, "")
  end
end
