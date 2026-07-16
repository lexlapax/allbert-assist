defmodule AllbertAssist.Runtime.MediaOutputs do
  @moduledoc """
  Normalized media-output envelope for channel-facing runtime responses.

  Image and audio provider actions return action-specific keys such as
  `:image_file` and `:audio_file`. Channels should consume this normalized
  envelope instead of depending on every provider action shape.
  """

  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.Redactor

  @mime_types_by_extension %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".wav" => "audio/wav",
    ".mp3" => "audio/mpeg",
    ".m4a" => "audio/mp4",
    ".ogg" => "audio/ogg",
    ".webm" => "audio/webm"
  }

  @type media_kind :: :image | :audio
  @type output :: %{
          required(:kind) => media_kind(),
          required(:source_action) => String.t(),
          required(:local_path) => String.t(),
          optional(:resource_uri) => String.t(),
          optional(:mime_type) => String.t(),
          optional(:filename) => String.t(),
          optional(:metadata) => map()
        }

  @doc "Collect completed generated media outputs from a runtime/action response."
  @spec collect(term()) :: [output()]
  def collect(response) when is_map(response) do
    existing_outputs = response |> field(:media_outputs, []) |> persistable()

    generated_outputs =
      response
      |> output_sources()
      |> Enum.flat_map(&collect_from_source/1)

    (existing_outputs ++ generated_outputs)
    |> Enum.uniq_by(fn output ->
      {field(output, :kind), field(output, :local_path), field(output, :resource_uri)}
    end)
  end

  def collect(_response), do: []

  @doc "Return the envelope shape safe to persist for local renderers."
  @spec persistable(term()) :: [map()]
  def persistable(outputs) when is_list(outputs) do
    outputs
    |> Enum.map(&persistable_output/1)
    |> Enum.reject(&is_nil/1)
  end

  def persistable(_outputs), do: []

  @doc "Return a channel-safe summary that excludes local filesystem paths."
  @spec redacted(term()) :: [map()]
  def redacted(outputs) do
    outputs
    |> persistable()
    |> Enum.map(&Map.delete(&1, :local_path))
  end

  defp output_sources(response) do
    [
      response,
      field(response, :output_data),
      field(response, :target_result)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp collect_from_source(source) when is_map(source) do
    []
    |> maybe_collect_image(source)
    |> maybe_collect_audio(source)
    |> Enum.reverse()
  end

  defp collect_from_source(_source), do: []

  defp maybe_collect_image(outputs, source) do
    case field(source, :image_file) do
      path when is_binary(path) and path != "" ->
        metadata = field(source, :image_metadata, %{}) || %{}

        [
          %{
            kind: :image,
            source_action: "generate_image",
            local_path: path,
            resource_uri:
              field(source, :output_resource_uri) ||
                field(metadata, :output_resource_uri) ||
                field(metadata, :generated_resource_uri),
            mime_type:
              normalize_mime_type(field(metadata, :mime_type)) ||
                mime_type_from_path(path, "image/png"),
            filename: field(metadata, :filename) || Path.basename(path),
            metadata: Redactor.redact_image_metadata(metadata)
          }
          |> drop_empty_values()
          | outputs
        ]

      _other ->
        outputs
    end
  end

  defp maybe_collect_audio(outputs, source) do
    case field(source, :audio_file) do
      path when is_binary(path) and path != "" ->
        metadata = field(source, :voice_metadata, %{}) || %{}

        [
          %{
            kind: :audio,
            source_action: "synthesize_voice",
            local_path: path,
            resource_uri:
              field(source, :output_resource_uri) || field(metadata, :output_resource_uri),
            mime_type:
              normalize_mime_type(field(metadata, :mime_type)) ||
                mime_type_from_path(path, "audio/wav"),
            filename: field(metadata, :filename) || Path.basename(path),
            metadata: Redactor.redact_audio_metadata(metadata)
          }
          |> drop_empty_values()
          | outputs
        ]

      _other ->
        outputs
    end
  end

  defp persistable_output(output) when is_map(output) do
    with kind when kind in [:image, :audio, "image", "audio"] <- field(output, :kind),
         local_path when is_binary(local_path) and local_path != "" <- field(output, :local_path) do
      %{
        kind: normalize_kind(kind),
        source_action: field(output, :source_action),
        local_path: local_path,
        resource_uri: field(output, :resource_uri),
        mime_type: normalize_mime_type(field(output, :mime_type)),
        filename: field(output, :filename),
        metadata: field(output, :metadata, %{})
      }
      |> drop_empty_values()
    else
      _other -> nil
    end
  end

  defp persistable_output(_output), do: nil

  defp normalize_kind(:image), do: :image
  defp normalize_kind("image"), do: :image
  defp normalize_kind(:audio), do: :audio
  defp normalize_kind("audio"), do: :audio

  defp mime_type_from_path(path, default) do
    extension = path |> Path.extname() |> String.downcase()
    Map.get(@mime_types_by_extension, extension, default)
  end

  defp normalize_mime_type(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      mime_type -> mime_type
    end
  end

  defp normalize_mime_type(_value), do: nil

  defp drop_empty_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, empty} when empty == %{} -> true
      _entry -> false
    end)
  end

  defp field(value, key, default \\ nil), do: Maps.field(value, key, default)
end
