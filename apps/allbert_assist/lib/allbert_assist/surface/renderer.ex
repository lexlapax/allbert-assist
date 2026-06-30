defmodule AllbertAssist.Surface.Renderer do
  @moduledoc """
  Shared renderer for runtime responses across Allbert surfaces.

  Surface adapters pass a descriptor that states which approval primitives and
  payload preference they support. This module owns the common response text,
  approval handoff, stream-event, media-output, and byte-bound rendering logic;
  adapters only wrap the rendered data in transport-specific envelopes.
  """

  alias AllbertAssist.Approval.Handoff
  alias AllbertAssist.Coding.StreamRenderer
  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.MediaOutputs
  alias AllbertAssist.Runtime.Response

  @default_max_text_bytes 4_000
  @default_descriptor %{
    primitives: [:typed_command, :list],
    threading: :reply_chain,
    payload: :message
  }

  @type descriptor :: map()
  @type approval_rendered :: %{
          required(:kind) => :approval_handoff,
          required(:text) => String.t(),
          required(:primitive) => atom(),
          required(:payload) => map()
        }
  @type rendered :: %{
          required(:kind) => :text | :stream | :approval_handoff,
          required(:text) => String.t(),
          required(:chunks) => [String.t()],
          optional(:primitive) => atom(),
          optional(:payload) => map()
        }

  @spec render_response(map(), descriptor(), keyword()) :: {:ok, rendered()}
  def render_response(response, descriptor \\ %{}, opts \\ []) when is_map(response) do
    descriptor = descriptor(descriptor, opts)
    response = Response.normalize(response)
    max_text_bytes = max_text_bytes(descriptor)

    rendered =
      cond do
        stream_events_enabled?(descriptor) and stream_events(response) ->
          render_stream_response(response, descriptor)

        handoff = field(response, :approval_handoff) ->
          render_approval_handoff(handoff, descriptor)

        true ->
          {:ok, %{kind: :text, text: response_text(response, descriptor)}}
      end

    with {:ok, rendered} <- rendered do
      text =
        rendered
        |> Map.fetch!(:text)
        |> normalize_if_requested(descriptor)
        |> bound_if_requested(descriptor, max_text_bytes)

      {:ok,
       rendered
       |> Map.put(:text, text)
       |> Map.put(:chunks, chunks(text, max_text_bytes))}
    end
  end

  @spec render_approval_handoff(map(), descriptor(), keyword()) :: {:ok, approval_rendered()}
  def render_approval_handoff(handoff_data, descriptor \\ %{}, opts \\ [])

  def render_approval_handoff(handoff_data, descriptor, opts) when is_map(handoff_data) do
    descriptor = descriptor(descriptor, opts)

    case Map.get(descriptor, :approval_text) do
      :typed_and_list ->
        render_combined_typed_and_list_handoff(handoff_data, descriptor)

      _other ->
        render_single_handoff(handoff_data, descriptor)
    end
  end

  def render_approval_handoff(_handoff_data, descriptor, opts) do
    descriptor = descriptor(descriptor, opts)
    text = Map.get(descriptor, :fallback_approval_text, "Approval required.")
    {:ok, %{kind: :approval_handoff, primitive: :text, payload: %{text: text}, text: text}}
  end

  @spec response_text(map(), descriptor()) :: String.t()
  def response_text(response, descriptor \\ %{}) when is_map(response) do
    descriptor = descriptor(descriptor)

    response
    |> payload_text(Map.get(descriptor, :payload, :message))
    |> with_media_outputs(response, descriptor)
  end

  @spec chunks(String.t(), pos_integer()) :: [String.t()]
  def chunks("", _limit), do: [""]

  def chunks(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
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

  @spec bound_text(String.t(), pos_integer(), String.t()) :: String.t()
  def bound_text(text, max_bytes, suffix \\ "...")

  def bound_text(text, max_bytes, _suffix) when is_binary(text) and byte_size(text) <= max_bytes,
    do: text

  def bound_text(text, max_bytes, suffix) when is_binary(text) do
    available = max(max_bytes - byte_size(suffix), 0)

    text
    |> byte_safe_prefix(available)
    |> String.trim_trailing()
    |> Kernel.<>(suffix)
  end

  @spec normalize_text(String.t()) :: String.t()
  def normalize_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.trim_trailing()
  end

  @spec field(term(), atom(), term()) :: term()
  def field(value, key, default \\ nil), do: Maps.field(value, key, default)

  defp descriptor(descriptor, opts \\ []) when is_map(descriptor) do
    @default_descriptor
    |> Map.merge(descriptor)
    |> Map.merge(Map.new(opts))
  end

  defp max_text_bytes(descriptor) do
    case Map.get(descriptor, :max_text_bytes, @default_max_text_bytes) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_max_text_bytes
    end
  end

  defp stream_events_enabled?(descriptor), do: Map.get(descriptor, :stream_events, false) == true

  defp render_stream_response(response, descriptor) do
    max_text_bytes = max_text_bytes(descriptor)
    events = stream_events(response)
    turn_id = field(response, :turn_id) || field(response, :id) || "turn"

    text =
      case StreamRenderer.render_events(events, turn_id: turn_id, max_text_bytes: max_text_bytes) do
        {:ok, rendered} -> rendered
        {:error, _reason} -> response_text(response, descriptor)
      end

    text =
      if Map.get(descriptor, :append_approval_handoff, false) == true do
        append_approval_handoff(text, response, descriptor)
      else
        text
      end

    {:ok, %{kind: :stream, text: text}}
  end

  defp append_approval_handoff(text, response, descriptor) do
    case field(response, :approval_handoff) do
      nil ->
        text

      handoff ->
        {:ok, %{text: handoff_text}} = render_approval_handoff(handoff, descriptor)
        Enum.join([text, handoff_text], "\n\n")
    end
  end

  defp stream_events(response) do
    case field(response, :stream_events) do
      [] -> nil
      nil -> nil
      events -> events
    end
  end

  defp render_single_handoff(handoff_data, descriptor) do
    case Handoff.render(handoff_data, descriptor) do
      {:ok, {primitive, payload}} ->
        {:ok,
         %{
           kind: :approval_handoff,
           primitive: primitive,
           payload: payload,
           text: handoff_text(primitive, payload, descriptor)
         }}

      {:error, _reason} ->
        text = Map.get(descriptor, :fallback_approval_text, "Approval required.")
        {:ok, %{kind: :approval_handoff, primitive: :text, payload: %{text: text}, text: text}}
    end
  end

  defp render_combined_typed_and_list_handoff(handoff_data, descriptor) do
    typed_descriptor = Map.put(descriptor, :primitives, [:typed_command])
    list_descriptor = Map.put(descriptor, :primitives, [:list])

    with {:ok, {:typed_command, typed_payload}} <- Handoff.render(handoff_data, typed_descriptor),
         {:ok, {:list, list_payload}} <- Handoff.render(handoff_data, list_descriptor) do
      text =
        [
          field(typed_payload, :text, "Approval required."),
          "",
          typed_intro(descriptor),
          command_lines(typed_payload),
          "",
          list_intro(descriptor),
          option_lines(list_payload)
        ]
        |> Enum.reject(&blank?/1)
        |> Enum.join("\n")

      {:ok,
       %{
         kind: :approval_handoff,
         primitive: :typed_and_list,
         payload: %{typed_command: typed_payload, list: list_payload},
         text: text
       }}
    else
      _error -> render_single_handoff(handoff_data, descriptor)
    end
  end

  defp handoff_text(:typed_command, payload, descriptor) do
    [
      field(payload, :text, "Approval required."),
      "",
      typed_intro(descriptor),
      command_lines(payload)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp handoff_text(:list, payload, descriptor) do
    [
      field(payload, :text, "Approval required."),
      "",
      list_intro(descriptor),
      option_lines(payload)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp handoff_text(:link, payload, descriptor) do
    [
      field(payload, :text, "Approval required."),
      "",
      Map.get(descriptor, :link_intro, "Open approval:"),
      field(payload, :url)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp handoff_text(_primitive, payload, _descriptor),
    do: field(payload, :text, "Approval required.")

  defp typed_intro(descriptor),
    do: Map.get(descriptor, :typed_intro, "Reply with one exact command:")

  defp list_intro(descriptor),
    do: Map.get(descriptor, :list_intro, "Reply with one option command:")

  defp command_lines(payload) do
    case field(payload, :commands) do
      commands when is_list(commands) -> Enum.map_join(commands, "\n", &"- #{&1}")
      _other -> nil
    end
  end

  defp option_lines(payload) do
    case field(payload, :numbered_options) do
      options when is_list(options) ->
        Enum.map_join(options, "\n", fn option ->
          "#{field(option, :index)}. #{field(option, :label)} - #{field(option, :command)}"
        end)

      _other ->
        nil
    end
  end

  defp payload_text(response, :surface_payload) do
    field(response, :surface_payload) || field(response, :message) ||
      field(response, :model_payload, "")
  end

  defp payload_text(response, :model_payload) do
    field(response, :model_payload) || field(response, :message) ||
      field(response, :surface_payload, "")
  end

  defp payload_text(response, _message) do
    field(response, :message) || field(response, :surface_payload) ||
      field(response, :model_payload, "")
  end

  defp with_media_outputs(text, response, descriptor) do
    if Map.get(descriptor, :media_outputs, false) == true do
      outputs =
        response
        |> field(:media_outputs, [])
        |> MediaOutputs.redacted()

      if outputs == [] do
        to_string(text)
      else
        to_string(text) <>
          "\n\nMedia outputs:\n" <> Enum.map_join(outputs, "\n", &media_output_line/1)
      end
    else
      to_string(text)
    end
  end

  defp media_output_line(output) do
    [
      "- #{field(output, :kind, "media")}",
      field(output, :mime_type),
      field(output, :resource_uri),
      field(output, :source_action)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp normalize_if_requested(text, descriptor) do
    if Map.get(descriptor, :normalize_text, false) == true do
      normalize_text(text)
    else
      text
    end
  end

  defp bound_if_requested(text, descriptor, max_text_bytes) do
    if Map.get(descriptor, :bound_text, false) == true do
      bound_text(text, max_text_bytes)
    else
      text
    end
  end

  defp byte_safe_prefix(text, max_bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, bytes} ->
      next_bytes = bytes + byte_size(grapheme)

      if next_bytes > max_bytes do
        {:halt, {acc, bytes}}
      else
        {:cont, {acc <> grapheme, next_bytes}}
      end
    end)
    |> elem(0)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
