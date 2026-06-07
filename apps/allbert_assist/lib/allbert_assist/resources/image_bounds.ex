defmodule AllbertAssist.Resources.ImageBounds do
  @moduledoc """
  Server-side image media bounds for vision input and generated image outputs.

  This module is pure policy plumbing: it validates metadata before an image
  reaches provider adapters or trace/audit surfaces. It does not decode image
  bytes or grant permission.
  """

  @allowed_formats ~w[png jpeg jpg webp gif]
  @default_max_bytes 20_971_520
  @default_max_pixels 33_177_600

  @type validation :: %{
          required(:format) => String.t(),
          required(:byte_size) => pos_integer(),
          required(:pixel_count) => pos_integer(),
          required(:max_bytes) => pos_integer(),
          required(:max_pixels) => pos_integer()
        }

  @doc "Validate operator-supplied image input metadata against settings and profile media."
  @spec validate_input(map(), map(), keyword() | map()) :: {:ok, validation()} | {:error, term()}
  def validate_input(metadata, profile_or_media, opts \\ []) do
    validate(metadata, profile_or_media, opts, %{
      bytes_setting: "vision.media.max_bytes",
      pixels_setting: "vision.media.max_pixels",
      size_error: :image_input_too_large,
      pixels_error: :image_input_too_many_pixels
    })
  end

  @doc "Validate generated image output metadata against settings and profile media."
  @spec validate_generated(map(), map(), keyword() | map()) ::
          {:ok, validation()} | {:error, term()}
  def validate_generated(metadata, profile_or_media, opts \\ []) do
    validate(metadata, profile_or_media, opts, %{
      bytes_setting: "image.generation.max_bytes",
      pixels_setting: "image.generation.max_pixels",
      size_error: :image_output_too_large,
      pixels_error: :image_output_too_many_pixels
    })
  end

  @doc "Return the static image-format vocabulary accepted by this helper."
  @spec allowed_formats() :: [String.t()]
  def allowed_formats, do: @allowed_formats

  defp validate(metadata, profile_or_media, opts, tags) when is_map(metadata) do
    with {:ok, media} <- media(profile_or_media),
         {:ok, supported_formats} <- supported_formats(media),
         {:ok, format} <- image_format(metadata),
         :ok <- validate_format(format, supported_formats),
         {:ok, byte_size} <- positive_metadata(metadata, "byte_size", :missing_image_byte_size),
         {:ok, pixel_count} <- pixel_count(metadata),
         {:ok, max_bytes} <-
           effective_bound(tags.bytes_setting, media, opts, "max_image_bytes"),
         {:ok, max_pixels} <-
           effective_bound(tags.pixels_setting, media, opts, "max_image_pixels"),
         :ok <- validate_size(byte_size, max_bytes, tags.size_error),
         :ok <- validate_pixels(pixel_count, max_pixels, tags.pixels_error) do
      {:ok,
       %{
         format: format,
         byte_size: byte_size,
         pixel_count: pixel_count,
         max_bytes: max_bytes,
         max_pixels: max_pixels
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate(_metadata, _profile_or_media, _opts, _tags), do: {:error, :invalid_image_metadata}

  defp media(%{media: media}) when is_map(media), do: {:ok, media}
  defp media(%{"media" => media}) when is_map(media), do: {:ok, media}
  defp media(media) when is_map(media), do: {:ok, media}
  defp media(_value), do: {:error, :missing_image_media_metadata}

  defp supported_formats(media) do
    formats =
      media
      |> field("image_formats_supported")
      |> normalize_formats()
      |> Enum.filter(&(&1 in @allowed_formats))

    if formats == [] do
      {:error, :missing_supported_image_formats}
    else
      {:ok, formats}
    end
  end

  defp validate_format(format, supported_formats) do
    if format in supported_formats do
      :ok
    else
      {:error, {:unsupported_image_format, format, supported_formats}}
    end
  end

  defp image_format(metadata) do
    [
      field(metadata, "image_format"),
      field(metadata, "format"),
      format_from_mime(field(metadata, "mime_type")),
      format_from_mime(field(metadata, "content_type")),
      format_from_path(field(metadata, "filename"))
    ]
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> {:error, :missing_image_format}
      format -> {:ok, format}
    end
  end

  defp positive_metadata(metadata, key, error) do
    case positive_integer(field(metadata, key)) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp pixel_count(metadata) do
    cond do
      positive_integer(field(metadata, "pixel_count")) ->
        {:ok, positive_integer(field(metadata, "pixel_count"))}

      positive_integer(field(metadata, "width")) && positive_integer(field(metadata, "height")) ->
        {:ok,
         positive_integer(field(metadata, "width")) * positive_integer(field(metadata, "height"))}

      true ->
        {:error, :missing_image_dimensions}
    end
  end

  defp effective_bound(settings_key, media, opts, media_key) do
    global_max =
      opts
      |> option(:settings, %{})
      |> dotted_positive_bound(settings_key)
      |> Kernel.||(default_bound(settings_key))

    global_max
    |> min_positive_bound(field(media, media_key) |> positive_integer())
    |> ok_positive_bound({:invalid_image_bound, settings_key})
  end

  defp default_bound("vision.media.max_bytes"), do: @default_max_bytes
  defp default_bound("image.generation.max_bytes"), do: @default_max_bytes
  defp default_bound("vision.media.max_pixels"), do: @default_max_pixels
  defp default_bound("image.generation.max_pixels"), do: @default_max_pixels

  defp validate_size(size, max_bytes, _error) when size <= max_bytes, do: :ok
  defp validate_size(size, max_bytes, error), do: {:error, {error, size, max_bytes}}

  defp validate_pixels(pixel_count, max_pixels, _error) when pixel_count <= max_pixels, do: :ok

  defp validate_pixels(pixel_count, max_pixels, error),
    do: {:error, {error, pixel_count, max_pixels}}

  defp normalize_formats(formats) when is_list(formats) do
    formats
    |> Enum.map(&normalize_format/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp normalize_formats(_formats), do: []

  defp normalize_format(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading(".")
    |> String.downcase()
    |> case do
      "" -> nil
      "jpg" -> "jpeg"
      format -> format
    end
  end

  defp normalize_format(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_format()

  defp normalize_format(_value), do: nil

  defp format_from_mime(value) when is_binary(value) do
    case String.split(String.downcase(String.trim(value)), "/", parts: 2) do
      ["image", subtype] -> normalize_format(subtype)
      _other -> nil
    end
  end

  defp format_from_mime(_value), do: nil

  defp format_from_path(value) when is_binary(value) do
    value
    |> Path.extname()
    |> normalize_format()
  end

  defp format_from_path(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp min_positive_bound(value, nil), do: value
  defp min_positive_bound(value, bound), do: min(value, bound)

  defp ok_positive_bound(value, _reason) when is_integer(value) and value > 0, do: {:ok, value}
  defp ok_positive_bound(_value, reason), do: {:error, reason}

  defp option(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp option(opts, key, default) when is_list(opts) do
    keys = [key, Atom.to_string(key)]

    case Enum.find(opts, fn
           {option_key, _value} -> option_key in keys
           _other -> false
         end) do
      {_option_key, value} -> value
      nil -> default
    end
  end

  defp option(_opts, _key, default), do: default

  defp dotted_positive_bound(settings, dotted_key) when is_map(settings) do
    Enum.reduce_while(String.split(dotted_key, "."), settings, fn key, acc ->
      case field(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
    |> positive_integer()
  end

  defp dotted_positive_bound(_settings, _dotted_key), do: nil

  defp field(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp field(_map, _key), do: nil
end
