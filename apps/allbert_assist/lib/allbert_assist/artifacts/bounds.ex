defmodule AllbertAssist.Artifacts.Bounds do
  @moduledoc """
  Pre-write artifact ingest bounds.

  This module validates byte size and MIME/type allow-lists before callers write
  durable artifact bytes. M3 will wire these same keys to the full
  `artifacts.*` Settings fragment; until then callers can pass explicit
  settings or operation options.
  """

  @default_max_bytes 20_971_520
  @default_allowed_mime ["*/*"]
  @default_allowed_types ["*"]

  @type validation :: %{
          required(:byte_size) => non_neg_integer(),
          required(:max_bytes) => pos_integer(),
          required(:mime) => String.t(),
          required(:allowed_mime) => [String.t()],
          required(:allowed_types) => [String.t()]
        }

  @doc "Validate artifact bytes and metadata before durable write."
  @spec validate(binary(), map(), keyword() | map()) :: {:ok, validation()} | {:error, term()}
  def validate(bytes, metadata, opts \\ [])

  def validate(bytes, metadata, opts) when is_binary(bytes) and is_map(metadata) do
    byte_size = byte_size(bytes)

    with {:ok, max_bytes} <- max_bytes(opts),
         :ok <- validate_size(byte_size, max_bytes),
         mime <- mime(metadata),
         allowed_mime <- allowed_mime(opts),
         allowed_types <- allowed_types(opts),
         :ok <- validate_mime(mime, allowed_mime),
         :ok <- validate_type(mime, allowed_types) do
      {:ok,
       %{
         byte_size: byte_size,
         max_bytes: max_bytes,
         mime: mime,
         allowed_mime: allowed_mime,
         allowed_types: allowed_types
       }}
    end
  end

  def validate(_bytes, _metadata, _opts), do: {:error, :invalid_artifact_bounds_input}

  defp max_bytes(opts) do
    opts
    |> option(:max_bytes)
    |> Kernel.||(dotted_setting(opts, "artifacts.max_bytes"))
    |> Kernel.||(@default_max_bytes)
    |> positive_integer()
    |> case do
      nil -> {:error, :invalid_artifact_max_bytes}
      value -> {:ok, value}
    end
  end

  defp validate_size(size, max_bytes) when size <= max_bytes, do: :ok
  defp validate_size(size, max_bytes), do: {:error, {:artifact_too_large, size, max_bytes}}

  defp mime(metadata) do
    metadata
    |> field(:mime)
    |> Kernel.||(field(metadata, :mime_type))
    |> Kernel.||(field(metadata, :content_type))
    |> normalize_mime()
    |> Kernel.||("application/octet-stream")
  end

  defp allowed_mime(opts) do
    opts
    |> option(:allowed_mime)
    |> Kernel.||(dotted_setting(opts, "artifacts.allowed_mime"))
    |> normalize_mime_list(@default_allowed_mime)
  end

  defp allowed_types(opts) do
    opts
    |> option(:allowed_types)
    |> Kernel.||(dotted_setting(opts, "artifacts.allowed_types"))
    |> normalize_type_list(@default_allowed_types)
  end

  defp validate_mime(_mime, ["*/*"]), do: :ok

  defp validate_mime(mime, allowed_mime) do
    if Enum.any?(allowed_mime, &mime_allowed?(mime, &1)) do
      :ok
    else
      {:error, {:artifact_mime_not_allowed, mime, allowed_mime}}
    end
  end

  defp mime_allowed?(mime, mime), do: true

  defp mime_allowed?(mime, allowed) do
    String.ends_with?(allowed, "/*") and
      mime_type(mime) == String.trim_trailing(allowed, "/*")
  end

  defp validate_type(_mime, ["*"]), do: :ok

  defp validate_type(mime, allowed_types) do
    type = mime_type(mime)

    if type in allowed_types do
      :ok
    else
      {:error, {:artifact_type_not_allowed, type, allowed_types}}
    end
  end

  defp mime_type(mime) do
    mime
    |> String.split("/", parts: 2)
    |> List.first()
  end

  defp normalize_mime(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      mime -> mime
    end
  end

  defp normalize_mime(_value), do: nil

  defp normalize_mime_list(values, default) do
    values
    |> list()
    |> Enum.map(&normalize_mime/1)
    |> Enum.filter(&valid_mime_pattern?/1)
    |> Enum.uniq()
    |> case do
      [] -> default
      values -> values
    end
  end

  defp normalize_type_list(values, default) do
    values
    |> list()
    |> Enum.map(&normalize_type/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> case do
      [] -> default
      values -> values
    end
  end

  defp valid_mime_pattern?("*/*"), do: true
  defp valid_mime_pattern?(value) when is_binary(value), do: String.contains?(value, "/")
  defp valid_mime_pattern?(_value), do: false

  defp normalize_type(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_type()

  defp normalize_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing("/*")
    |> String.downcase()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_type(_value), do: nil

  defp list(nil), do: []
  defp list(values) when is_list(values), do: values
  defp list(value) when is_binary(value) or is_atom(value), do: [value]
  defp list(_value), do: []

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp option(opts, key) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key)))
  end

  defp option(opts, key) when is_list(opts) do
    string_key = Atom.to_string(key)

    case Enum.find(opts, fn
           {option_key, _value} -> option_key in [key, string_key]
           _other -> false
         end) do
      {_option_key, value} -> value
      nil -> nil
    end
  end

  defp option(_opts, _key), do: nil

  defp dotted_setting(opts, dotted_key) do
    opts
    |> option(:settings)
    |> case do
      settings when is_map(settings) -> dotted_value(settings, dotted_key)
      _settings -> nil
    end
  end

  defp dotted_value(settings, dotted_key) do
    Enum.reduce_while(String.split(dotted_key, "."), settings, fn key, acc ->
      case field(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_atom(key)))
  end

  defp field(_map, _key), do: nil
end
