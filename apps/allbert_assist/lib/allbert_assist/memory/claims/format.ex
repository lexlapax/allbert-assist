defmodule AllbertAssist.Memory.Claims.Format do
  @moduledoc false

  @new_header "# Allbert Memory Claim Stream v1\n"
  @delimiter "\n<!-- allbert-claim-stream:v1 -->\n"
  @record_header ~r/\A<!-- allbert-claim-revision:v1 bytes=([1-9][0-9]*) -->\n/
  @max_record_bytes 16 * 1024 * 1024

  @type decoded :: %{legacy_content: String.t() | nil, records: [map()]}

  def new_header, do: @new_header

  @spec parse(String.t()) :: {:ok, decoded()} | {:error, term()}
  def parse(content) when is_binary(content) do
    case :binary.matches(content, @delimiter) do
      [] ->
        {:error, :not_claim_stream}

      matches ->
        {position, length} = List.last(matches)
        prefix = binary_part(content, 0, position)
        stream_offset = position + length
        stream = binary_part(content, stream_offset, byte_size(content) - stream_offset)
        parse_stream(prefix, stream)
    end
  end

  @spec render(String.t() | nil, [map()]) :: String.t()
  def render(legacy_content, records) when is_list(records) do
    prefix = if is_binary(legacy_content), do: legacy_content, else: @new_header
    prefix <> @delimiter <> Enum.map_join(records, "", &render_record/1)
  end

  @spec canonical_json(term()) :: String.t()
  def canonical_json(value), do: encode_json(stringify(value))

  defp parse_stream(prefix, stream) do
    with {:ok, records} <- decode_records(stream) do
      legacy_content = if prefix == @new_header, do: nil, else: prefix
      {:ok, %{legacy_content: legacy_content, records: records}}
    end
  end

  defp decode_records(stream) do
    decode_records(stream, [])
  end

  defp decode_records("", records), do: {:ok, Enum.reverse(records)}

  defp decode_records(stream, records) do
    with [header, length_text] <- Regex.run(@record_header, stream),
         {length, ""} <- Integer.parse(length_text),
         true <- length <= @max_record_bytes || {:error, :revision_record_too_large},
         true <-
           byte_size(stream) >= byte_size(header) + length + 1 ||
             {:error, :truncated_revision_record},
         <<_header::binary-size(byte_size(header)), json::binary-size(length), "\n",
           rest::binary>> <-
           stream,
         {:ok, %{} = record} <- decode_record(json),
         true <- canonical_json(record) == json || {:error, :noncanonical_revision_json} do
      decode_records(rest, [record | records])
    else
      nil -> {:error, :unexpected_claim_stream_content}
      :error -> {:error, :invalid_revision_length}
      {:ok, _other} -> {:error, :invalid_revision_record}
      {:error, _reason} = error -> error
      _other -> {:error, :unexpected_claim_stream_content}
    end
  end

  defp render_record(record) do
    json = canonical_json(record)
    "<!-- allbert-claim-revision:v1 bytes=#{byte_size(json)} -->\n" <> json <> "\n"
  end

  defp decode_record(json) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, :invalid_revision_json}
    end
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp stringify(value), do: value

  defp encode_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> encode_json(value) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp encode_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &encode_json/1) <> "]"

  defp encode_json(value), do: Jason.encode!(value)
end
