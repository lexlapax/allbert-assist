defmodule AllbertAssist.Artifacts.MediaRetention do
  @moduledoc """
  Retained media ingestion into Artifacts Central.

  Legacy media roots remain backfill inputs. New retained media writes use the
  content-addressable artifact store and keep only bounded provenance metadata.
  """

  alias AllbertAssist.Artifacts.IngestionConsumer
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Paths

  @type kind :: :voice_audio | :vision_media | :generated_image

  @extension_mimes %{
    ".flac" => "audio/flac",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".m4a" => "audio/mp4",
    ".mp3" => "audio/mpeg",
    ".ogg" => "audio/ogg",
    ".png" => "image/png",
    ".wav" => "audio/wav",
    ".webm" => "audio/webm",
    ".webp" => "image/webp"
  }

  @doc "Store retained media bytes through the artifact retention policy."
  @spec put(kind(), binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(kind, bytes, attrs \\ %{}, opts \\ []) when is_binary(bytes) and is_map(attrs) do
    with {:ok, spec} <- source_spec(kind),
         metadata <- artifact_metadata(spec, bytes, attrs),
         {:ok, artifact} <- IngestionConsumer.ingest(bytes, metadata, opts) do
      {:ok, Map.put(artifact, :path, Store.object_path!(artifact.sha256))}
    end
  end

  @doc "Return the source spec for a retained-media kind."
  @spec source_spec(kind()) :: {:ok, map()} | {:error, term()}
  def source_spec(:voice_audio) do
    {:ok,
     %{
       kind: :voice_audio,
       origin: "retained_voice_audio",
       legacy_root_setting: "voice.audio.retention_root",
       default_root: &Paths.audio_root/0
     }}
  end

  def source_spec(:vision_media) do
    {:ok,
     %{
       kind: :vision_media,
       origin: "retained_vision_media",
       legacy_root_setting: "vision.media.retention_root",
       default_root: &Paths.images_root/0
     }}
  end

  def source_spec(:generated_image) do
    {:ok,
     %{
       kind: :generated_image,
       origin: "retained_generated_image",
       legacy_root_setting: "image.generation.retention_root",
       default_root: &Paths.generated_images_root/0
     }}
  end

  def source_spec(kind), do: {:error, {:unknown_retained_media_kind, kind}}

  @doc "Return a conservative MIME value from attrs or a filename extension."
  @spec mime(map()) :: String.t()
  def mime(attrs) when is_map(attrs) do
    case attrs_mime(attrs) do
      value when is_binary(value) ->
        value

      nil ->
        case mime_from_extension(field(attrs, :filename) || field(attrs, :path)) do
          value when is_binary(value) -> value
          nil -> "application/octet-stream"
        end
    end
  end

  def mime(_attrs), do: "application/octet-stream"

  @doc "Expand a root setting value that may contain <ALLBERT_HOME>."
  @spec expand_home_path(String.t()) :: String.t()
  def expand_home_path(path) when is_binary(path) do
    path
    |> String.replace("<ALLBERT_HOME>", Paths.home())
    |> Path.expand()
  end

  def expand_home_path(_path), do: Paths.home()

  defp artifact_metadata(spec, bytes, attrs) do
    %{
      mime: mime(attrs),
      origin: spec.origin,
      source_resource_uri: safe_source_resource_uri(attrs),
      provenance: %{
        "media_retention" => media_provenance(spec, bytes, attrs)
      }
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp media_provenance(spec, bytes, attrs) do
    %{
      "kind" => Atom.to_string(spec.kind),
      "legacy_root_setting" => spec.legacy_root_setting,
      "capture_id" => field(attrs, :capture_id),
      "original_extension" => extension(field(attrs, :filename) || field(attrs, :path)),
      "relative_path_sha256" => field(attrs, :relative_path_sha256),
      "content_sha256" => Store.sha256(bytes)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp safe_source_resource_uri(attrs) do
    case field(attrs, :source_resource_uri) || field(attrs, :resource_uri) do
      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          String.starts_with?(value, "mic://capture/") -> value
          String.starts_with?(value, "image://capture/") -> value
          String.starts_with?(value, "artifact://sha256/") -> value
          true -> nil
        end

      _value ->
        nil
    end
  end

  defp normalize_mime(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_mime(_value), do: nil

  defp attrs_mime(attrs) do
    attrs
    |> field(:mime)
    |> Kernel.||(field(attrs, :mime_type))
    |> Kernel.||(field(attrs, :content_type))
    |> normalize_mime()
  end

  defp mime_from_extension(path) when is_binary(path) do
    Map.get(@extension_mimes, path |> Path.extname() |> String.downcase())
  end

  defp mime_from_extension(_path), do: nil

  defp extension(path) when is_binary(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp extension(_path), do: nil

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
