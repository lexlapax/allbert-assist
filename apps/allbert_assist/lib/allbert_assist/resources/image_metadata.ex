defmodule AllbertAssist.Resources.ImageMetadata do
  @moduledoc """
  Server-side image metadata extraction for bounded vision inputs.

  The helpers parse only enough header data to validate format and dimensions.
  They do not transform, resize, or decode full image pixels.
  """

  @default_max_read_bytes 20_971_520
  @jpeg_sof_markers MapSet.new([
                      0xC0,
                      0xC1,
                      0xC2,
                      0xC3,
                      0xC5,
                      0xC6,
                      0xC7,
                      0xC9,
                      0xCA,
                      0xCB,
                      0xCD,
                      0xCE,
                      0xCF
                    ])
  @jpeg_standalone_markers MapSet.new([
                             0x01,
                             0xD0,
                             0xD1,
                             0xD2,
                             0xD3,
                             0xD4,
                             0xD5,
                             0xD6,
                             0xD7,
                             0xD8,
                             0xD9
                           ])

  @type metadata :: %{
          required(:path) => String.t(),
          required(:byte_size) => pos_integer(),
          required(:image_format) => String.t(),
          required(:mime_type) => String.t(),
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          required(:pixel_count) => pos_integer(),
          required(:content_sha256) => String.t(),
          required(:redaction_status) => String.t(),
          optional(:resource_uri) => String.t(),
          optional(:filename) => String.t(),
          optional(:transient?) => boolean()
        }

  @doc "Extract bounded metadata from an image file path."
  @spec from_path(term(), keyword() | map()) :: {:ok, metadata()} | {:error, term()}
  def from_path(path, opts \\ []) do
    with {:ok, path} <- path(path),
         {:ok, stat} <- File.stat(path),
         :ok <- validate_size(stat.size, max_read_bytes(opts)),
         {:ok, bytes} <- File.read(path),
         {:ok, format, width, height} <- identify(bytes, Path.extname(path)) do
      {:ok,
       %{
         path: path,
         byte_size: stat.size,
         image_format: format,
         mime_type: mime_type(format),
         width: width,
         height: height,
         pixel_count: width * height,
         content_sha256: sha256(bytes),
         redaction_status: "metadata_only"
       }
       |> maybe_put(:resource_uri, option(opts, :resource_uri, nil))
       |> maybe_put(:filename, option(opts, :filename, nil))
       |> maybe_put(:transient?, option(opts, :transient?, nil))}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp path(path) when is_binary(path) do
    path = String.trim(path)
    if path == "", do: {:error, :missing_image_path}, else: {:ok, Path.expand(path)}
  end

  defp path(_path), do: {:error, :invalid_image_path}

  defp validate_size(size, max_bytes) when is_integer(size) and size > 0 and size <= max_bytes,
    do: :ok

  defp validate_size(size, max_bytes) when is_integer(size) and size > max_bytes,
    do: {:error, {:image_input_too_large, size, max_bytes}}

  defp validate_size(_size, _max_bytes), do: {:error, :empty_image_file}

  defp identify(
         <<0x89, ?P, ?N, ?G, 0x0D, 0x0A, 0x1A, 0x0A, _length::32, "IHDR", width::32, height::32,
           _rest::binary>>,
         _extension
       )
       when width > 0 and height > 0,
       do: {:ok, "png", width, height}

  defp identify(<<0xFF, 0xD8, rest::binary>>, _extension), do: jpeg_dimensions(rest)

  defp identify(
         <<"RIFF", _size::little-32, "WEBP", "VP8X", _chunk_size::little-32, _flags,
           width_minus_one::little-24, height_minus_one::little-24, _rest::binary>>,
         _extension
       ) do
    {:ok, "webp", width_minus_one + 1, height_minus_one + 1}
  end

  defp identify(_bytes, extension) do
    {:error, {:unsupported_image_file_type, normalize_extension(extension)}}
  end

  defp jpeg_dimensions(<<0xFF, marker, rest::binary>>) do
    cond do
      marker == 0xFF ->
        jpeg_dimensions(rest)

      MapSet.member?(@jpeg_standalone_markers, marker) ->
        jpeg_dimensions(rest)

      byte_size(rest) < 2 ->
        {:error, :invalid_jpeg_header}

      MapSet.member?(@jpeg_sof_markers, marker) ->
        jpeg_sof_dimensions(rest)

      true ->
        jpeg_skip_segment(rest)
    end
  end

  defp jpeg_dimensions(<<_byte, rest::binary>>), do: jpeg_dimensions(rest)
  defp jpeg_dimensions(_bytes), do: {:error, :invalid_jpeg_header}

  defp jpeg_sof_dimensions(<<length::16, tail::binary>>) do
    segment_size = length - 2

    with true <- segment_size >= 5,
         true <- byte_size(tail) >= segment_size,
         <<segment::binary-size(segment_size), _next::binary>> <- tail do
      jpeg_segment_dimensions(segment)
    else
      _other -> {:error, :invalid_jpeg_header}
    end
  end

  defp jpeg_sof_dimensions(_rest), do: {:error, :invalid_jpeg_header}

  defp jpeg_segment_dimensions(<<_precision, height::16, width::16, _rest::binary>>)
       when width > 0 and height > 0,
       do: {:ok, "jpeg", width, height}

  defp jpeg_segment_dimensions(_segment), do: {:error, :invalid_jpeg_header}

  defp jpeg_skip_segment(<<length::16, tail::binary>>) do
    skip = length - 2

    cond do
      skip < 0 ->
        {:error, :invalid_jpeg_header}

      byte_size(tail) >= skip ->
        <<_segment::binary-size(skip), next::binary>> = tail
        jpeg_dimensions(next)

      true ->
        {:error, :invalid_jpeg_header}
    end
  end

  defp jpeg_skip_segment(_rest), do: {:error, :invalid_jpeg_header}

  defp max_read_bytes(opts) do
    case option(opts, :max_bytes, @default_max_read_bytes) do
      value when is_integer(value) and value > 0 -> value
      _value -> @default_max_read_bytes
    end
  end

  defp mime_type("png"), do: "image/png"
  defp mime_type("jpeg"), do: "image/jpeg"
  defp mime_type("webp"), do: "image/webp"
  defp mime_type(format), do: "image/#{format}"

  defp sha256(bytes) do
    :sha256
    |> :crypto.hash(bytes)
    |> Base.encode16(case: :lower)
  end

  defp normalize_extension(extension) when is_binary(extension) do
    extension
    |> String.trim()
    |> String.trim_leading(".")
    |> String.downcase()
    |> case do
      "" -> "unknown"
      "jpg" -> "jpeg"
      value -> value
    end
  end

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
