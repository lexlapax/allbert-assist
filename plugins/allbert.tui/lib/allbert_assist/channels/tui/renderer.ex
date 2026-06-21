defmodule AllbertAssist.Channels.TUI.Renderer do
  @moduledoc false

  alias AllbertAssist.Approval.Handoff

  @default_max_text_bytes 12_000
  @descriptor %{primitives: [:typed_command, :list], threading: :rich}

  @spec banner(String.t()) :: [Owl.Data.t()]
  def banner(profile) do
    [["Allbert TUI ", Owl.Data.tag("(#{profile})", :cyan)], "Type /quit to exit."]
  end

  @spec prompt(String.t()) :: Owl.Data.t()
  def prompt(profile), do: [Owl.Data.tag("allbert", :cyan), ":", profile, "> "]

  @spec status(String.t(), atom()) :: Owl.Data.t()
  def status(profile, state), do: [prompt(profile), Owl.Data.tag(to_string(state), :light_black)]

  @spec render_response(map(), keyword()) :: {:ok, [String.t()]}
  def render_response(response, opts \\ []) when is_map(response) do
    max_text_bytes = Keyword.get(opts, :max_text_bytes, @default_max_text_bytes)

    response_text =
      if handoff = response_field(response, :approval_handoff) do
        render_approval_handoff(handoff)
      else
        surface_text(response)
      end

    response_text
    |> normalize_text()
    |> bound_text(max_text_bytes)
    |> then(&{:ok, [&1]})
  end

  def render_approval_handoff(handoff_data) do
    with {:ok, {:typed_command, typed_payload}} <- Handoff.render(handoff_data, @descriptor),
         {:ok, {:list, list_payload}} <- Handoff.render(handoff_data, %{primitives: [:list]}) do
      combined_handoff_text(typed_payload, list_payload)
    else
      _error -> fallback_approval_handoff(handoff_data)
    end
  end

  defp fallback_approval_handoff(handoff_data) do
    with {:ok, {primitive, payload}} <- Handoff.render(handoff_data, @descriptor) do
      render_handoff_payload(primitive, payload)
    else
      _error -> "Approval required."
    end
  end

  defp combined_handoff_text(typed_payload, list_payload) do
    [
      response_field(typed_payload, :text, "Approval required."),
      "",
      "Type one exact command:",
      command_lines(typed_payload),
      "",
      "Approval options:",
      option_lines(list_payload)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  def confirmation_reply(response) when is_map(response) do
    response
    |> response_field(:message, inspect(response, pretty: true))
    |> to_string()
  end

  defp render_handoff_payload(:typed_command, payload), do: typed_command_text(payload)
  defp render_handoff_payload(:list, payload), do: numbered_options_text(payload)

  defp render_handoff_payload(_primitive, payload),
    do: response_field(payload, :text, "Approval required.")

  defp typed_command_text(%{text: text, commands: commands}) when is_list(commands) do
    [
      text,
      "",
      "Type one exact command:",
      command_lines(%{commands: commands})
    ]
    |> Enum.join("\n")
  end

  defp typed_command_text(%{text: text}), do: text

  defp numbered_options_text(%{text: text, numbered_options: options}) when is_list(options) do
    [
      text,
      "",
      "Approval options:",
      option_lines(%{numbered_options: options})
    ]
    |> Enum.join("\n")
  end

  defp numbered_options_text(%{text: text}), do: text

  defp command_lines(%{commands: commands}) when is_list(commands) do
    Enum.map_join(commands, "\n", &"- #{&1}")
  end

  defp command_lines(_payload), do: nil

  defp option_lines(%{numbered_options: options}) when is_list(options) do
    Enum.map_join(options, "\n", fn option ->
      "#{Map.get(option, :index)}. #{Map.get(option, :label)} - #{Map.get(option, :command)}"
    end)
  end

  defp option_lines(_payload), do: nil

  defp surface_text(%{surface_payload: payload}) when is_binary(payload), do: payload
  defp surface_text(%{"surface_payload" => payload}) when is_binary(payload), do: payload
  defp surface_text(%{message: message}) when is_binary(message), do: message
  defp surface_text(%{"message" => message}) when is_binary(message), do: message
  defp surface_text(%{model_payload: payload}) when is_binary(payload), do: payload
  defp surface_text(%{"model_payload" => payload}) when is_binary(payload), do: payload
  defp surface_text(_response), do: ""

  defp response_field(map, key, default \\ nil)

  defp response_field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp response_field(_map, _key, default), do: default

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.trim_trailing()
  end

  defp bound_text(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp bound_text(text, max_bytes) do
    text
    |> binary_part(0, max_bytes)
    |> String.trim_trailing()
    |> Kernel.<>("...")
  end

  defp blank?(value), do: value in [nil, ""]
end
