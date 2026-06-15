defmodule AllbertAssist.Channels.WhatsApp.Renderer do
  @moduledoc false

  alias AllbertAssist.Approval.Handoff

  @default_limit 4096
  @button_title_limit 20
  @button_id_limit 256

  def render_response(runtime_response, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_text_bytes, @default_limit) |> min(@default_limit)

    if handoff = response_field(runtime_response, :approval_handoff) do
      render_approval_handoff(handoff, opts)
    else
      text =
        runtime_response
        |> response_field(:message, "")
        |> to_string()

      {:ok, Enum.map(chunks(text, max_bytes), &%{type: :text, body: &1})}
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
        [:button, :typed_command, :link, :list]
      else
        [:typed_command, :link, :list]
      end

    %{primitives: primitives, threading: :reply_chain}
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

  defp bounded(value, limit) do
    value
    |> to_string()
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, bytes} ->
      grapheme_bytes = byte_size(grapheme)

      if bytes + grapheme_bytes > limit do
        {:halt, {acc, bytes}}
      else
        {:cont, {acc <> grapheme, bytes + grapheme_bytes}}
      end
    end)
    |> elem(0)
  end

  defp response_field(map, key, default \\ nil)

  defp response_field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp response_field(_map, _key, default), do: default
end
