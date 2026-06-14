defmodule AllbertAssist.Channels.Telegram.Renderer do
  @moduledoc false

  alias AllbertAssist.Approval.Handoff
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
    descriptor = effective_descriptor(opts)

    with {:ok, {primitive, payload}} <- Handoff.render(handoff_data, descriptor) do
      {text, keyboard} = render_handoff_payload(primitive, payload, handoff_data)

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
    with {:ok, {primitive, payload}} <-
           Handoff.render(handoff_data, %{primitives: [:typed_command, :list], threading: :reply_chain}) do
      render_handoff_payload(primitive, payload, handoff_data)
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

    %{primitives: primitives, threading: :reply_chain}
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
