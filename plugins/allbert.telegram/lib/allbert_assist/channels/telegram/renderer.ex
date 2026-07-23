defmodule AllbertAssist.Channels.Telegram.Renderer do
  @moduledoc false

  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  @telegram_limit 4096
  @callback_limit 64
  @descriptor %{
    primitives: [:button, :typed_command, :list],
    threading: :reply_chain,
    payload: :message,
    media_outputs: true
  }

  def render_response(runtime_response, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_text_bytes, @telegram_limit)

    with {:ok, rendered} <-
           SurfaceRenderer.render_response(runtime_response, effective_descriptor(opts),
             max_text_bytes: min(max_bytes, @telegram_limit)
           ) do
      case rendered.kind do
        :approval_handoff ->
          {text, keyboard} =
            render_handoff_payload(
              rendered.primitive,
              rendered.payload,
              response_field(runtime_response, :approval_handoff)
            )

          {:ok, SurfaceRenderer.chunks(text, @telegram_limit), keyboard}

        _kind ->
          {:ok, rendered.chunks, notify_offer_keyboard(runtime_response, opts)}
      end
    end
  end

  def render_approval_handoff(handoff_data, opts \\ []) do
    with {:ok, rendered} <-
           SurfaceRenderer.render_approval_handoff(handoff_data, effective_descriptor(opts)) do
      {text, keyboard} =
        render_handoff_payload(rendered.primitive, rendered.payload, handoff_data)

      {:ok, chunks(text, @telegram_limit), keyboard}
    end
  end

  defp render_handoff_payload(:button, payload, handoff_data) do
    case approval_keyboard(payload) do
      nil ->
        fallback_handoff_payload(handoff_data)

      keyboard ->
        {payload.text, keyboard}
    end
  end

  defp render_handoff_payload(:typed_command, payload, _handoff_data) do
    {typed_command_text(payload), nil}
  end

  defp render_handoff_payload(:list, payload, _handoff_data) do
    {numbered_options_text(payload), nil}
  end

  defp render_handoff_payload(_primitive, payload, _handoff_data), do: {payload.text, nil}

  defp fallback_handoff_payload(handoff_data) do
    with {:ok, rendered} <-
           SurfaceRenderer.render_approval_handoff(handoff_data, %{
             primitives: [:typed_command, :list],
             threading: :reply_chain
           }) do
      render_handoff_payload(rendered.primitive, rendered.payload, handoff_data)
    else
      _error -> {"Approval required.", nil}
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

  defp approval_keyboard(%{buttons: buttons}) when is_list(buttons) do
    buttons =
      Enum.flat_map(buttons, fn button ->
        data = Map.get(button, :callback_data)
        label = Map.get(button, :label)

        if is_binary(data) and is_binary(label) and byte_size(data) <= @callback_limit do
          [[%{"text" => label, "callback_data" => data}]]
        else
          []
        end
      end)

    if buttons == [], do: nil, else: %{"inline_keyboard" => buttons}
  end

  defp approval_keyboard(_payload), do: nil

  defp notify_offer_keyboard(response, opts) do
    if response_field(response, :notify_offer) && Keyword.get(opts, :render_buttons, true) do
      %{
        "inline_keyboard" => [
          [%{"text" => "Enable notifications", "callback_data" => "ALLBERT:NOTIFY:ON"}]
        ]
      }
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

  defp response_field(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
