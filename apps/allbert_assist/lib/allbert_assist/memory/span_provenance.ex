defmodule AllbertAssist.Memory.SpanProvenance do
  @moduledoc """
  Mechanical grounding for conversation-derived Memory proposal fields.

  Coordinates are UTF-8 byte offsets into canonical operator-authored Corpus
  content. Only the five versioned transforms frozen by ADR 0089 are accepted;
  model output and assistant text cannot satisfy this boundary.
  """

  alias AllbertAssist.Conversations.SourceEnvelope

  @transforms ~w[identity_v1 trim_ascii_whitespace_v1 ascii_lower_v1 operator_pronoun_v1 explicit_iso8601_date_v1]
  @digest_pattern ~r/^sha256:[0-9a-f]{64}$/
  @date_pattern ~r/^\d{4}-\d{2}-\d{2}$/

  @doc "Return the closed v1 transform vocabulary."
  def transforms, do: @transforms

  @doc "Build one verified field record from a canonical source byte span."
  def build(field, %SourceEnvelope{} = source, byte_start, byte_end, transform)
      when is_binary(field) and is_integer(byte_start) and is_integer(byte_end) and
             is_binary(transform) do
    with :ok <- operator_source(source),
         {:ok, raw} <- slice(source.content, byte_start, byte_end),
         {:ok, normalized} <- transform(raw, transform, source.operator_id) do
      {:ok,
       %{
         "field" => field,
         "source_id" => source.source_id,
         "source_digest" => source.content_digest,
         "byte_start" => byte_start,
         "byte_end" => byte_end,
         "raw_span_digest" => digest(raw),
         "normalized_value" => normalized,
         "transform" => transform
       }}
    end
  end

  def build(_field, _source, _byte_start, _byte_end, _transform),
    do: {:error, :invalid_span}

  @doc "Verify exact field coverage against current canonical source envelopes."
  def verify(claim, provenance, sources)
      when is_map(claim) and is_map(provenance) and is_list(sources) do
    source_map = Map.new(sources, &{&1.source_id, &1})
    fields = map_field(provenance, "fields")

    with true <- is_list(fields) || {:error, :invalid_span_provenance},
         :ok <- unique_field_bindings(fields),
         {:ok, verified} <- verify_fields(fields, source_map),
         :ok <- exact_coverage(claim, verified) do
      {:ok, %{"schema_version" => 1, "fields" => verified}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_span_provenance}
    end
  end

  def verify(_claim, _provenance, _sources), do: {:error, :invalid_span_provenance}

  defp verify_fields(fields, sources) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, acc} ->
      case verify_field(field, sources) do
        {:ok, verified} -> {:cont, {:ok, [verified | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, verified} -> {:ok, Enum.reverse(verified)}
      error -> error
    end
  end

  defp verify_field(field, sources) when is_map(field) do
    field = stringify(field)

    with {:ok, name} <- required_binary(field, "field"),
         {:ok, source_id} <- required_binary(field, "source_id"),
         %SourceEnvelope{} = source <- Map.get(sources, source_id),
         :ok <- operator_source(source),
         true <-
           field["source_digest"] == source.content_digest || {:error, :source_digest_mismatch},
         true <-
           Regex.match?(@digest_pattern, field["source_digest"]) ||
             {:error, :invalid_source_digest},
         {:ok, byte_start} <- required_offset(field, "byte_start"),
         {:ok, byte_end} <- required_offset(field, "byte_end"),
         {:ok, raw} <- slice(source.content, byte_start, byte_end),
         true <- field["raw_span_digest"] == digest(raw) || {:error, :raw_span_digest_mismatch},
         {:ok, normalized} <- transform(raw, field["transform"], source.operator_id),
         true <- field["normalized_value"] == normalized || {:error, :normalized_value_mismatch} do
      {:ok,
       %{
         "field" => name,
         "source_id" => source_id,
         "source_digest" => source.content_digest,
         "byte_start" => byte_start,
         "byte_end" => byte_end,
         "raw_span_digest" => digest(raw),
         "normalized_value" => normalized,
         "transform" => field["transform"]
       }}
    else
      nil -> {:error, :span_source_unavailable}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_span_field}
    end
  end

  defp verify_field(_field, _sources), do: {:error, :invalid_span_field}

  defp exact_coverage(claim, verified) do
    expected = scalar_fields(stringify(claim)) |> Map.new()
    actual = Map.new(verified, &{&1["field"], &1["normalized_value"]})

    cond do
      map_size(expected) == 0 -> {:error, :empty_proposed_claim}
      Map.keys(actual) -- Map.keys(expected) != [] -> {:error, :unknown_claim_field}
      Map.keys(expected) -- Map.keys(actual) != [] -> {:error, :uncovered_claim_field}
      Enum.all?(expected, fn {field, value} -> actual[field] == value end) -> :ok
      true -> {:error, :claim_field_value_mismatch}
    end
  end

  defp scalar_fields(map, prefix \\ nil)

  defp scalar_fields(map, prefix) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {key, value} ->
      path = if prefix, do: prefix <> "." <> key, else: key
      scalar_fields(value, path)
    end)
  end

  defp scalar_fields(nil, _prefix), do: []
  defp scalar_fields(value, prefix) when is_binary(value), do: [{prefix, value}]
  defp scalar_fields(_value, _prefix), do: []

  defp unique_field_bindings(fields) do
    names = Enum.map(fields, &map_field(&1, "field"))

    if Enum.all?(names, &is_binary/1) and Enum.uniq(names) == names,
      do: :ok,
      else: {:error, :duplicate_or_invalid_field_binding}
  end

  defp operator_source(%SourceEnvelope{author: :operator, trust: :private_operator}), do: :ok
  defp operator_source(%SourceEnvelope{}), do: {:error, :operator_source_required}

  defp slice(content, byte_start, byte_end)
       when is_binary(content) and byte_start >= 0 and byte_end > byte_start and
              byte_end <= byte_size(content) do
    raw = binary_part(content, byte_start, byte_end - byte_start)
    if String.valid?(raw), do: {:ok, raw}, else: {:error, :invalid_utf8_span_boundary}
  end

  defp slice(_content, _byte_start, _byte_end), do: {:error, :invalid_span_bounds}

  defp transform(raw, "identity_v1", _operator_id), do: {:ok, raw}

  defp transform(raw, "trim_ascii_whitespace_v1", _operator_id),
    do: {:ok, trim_ascii_whitespace(raw)}

  defp transform(raw, "ascii_lower_v1", _operator_id) do
    if ascii?(raw), do: {:ok, ascii_lower(raw)}, else: {:error, :non_ascii_transform_input}
  end

  defp transform(raw, "operator_pronoun_v1", operator_id) do
    if ascii_lower(raw) in ["i", "me", "my"],
      do: {:ok, "operator:" <> operator_id},
      else: {:error, :invalid_operator_pronoun}
  end

  defp transform(raw, "explicit_iso8601_date_v1", _operator_id) do
    if Regex.match?(@date_pattern, raw) do
      case Date.from_iso8601(raw) do
        {:ok, _date} -> {:ok, raw}
        {:error, _reason} -> {:error, :invalid_explicit_date}
      end
    else
      {:error, :date_not_explicit}
    end
  end

  defp transform(_raw, transform, _operator_id) when is_binary(transform),
    do: {:error, :unsupported_span_transform}

  defp transform(_raw, _transform, _operator_id), do: {:error, :invalid_span_transform}

  defp required_binary(map, key) do
    value = map[key]
    if is_binary(value) and value != "", do: {:ok, value}, else: {:error, :invalid_span_field}
  end

  defp required_offset(map, key) do
    value = map[key]
    if is_integer(value) and value >= 0, do: {:ok, value}, else: {:error, :invalid_span_bounds}
  end

  defp map_field(map, "fields") when is_map(map),
    do: Map.get(map, "fields", Map.get(map, :fields))

  defp map_field(map, "field") when is_map(map), do: Map.get(map, "field", Map.get(map, :field))
  defp map_field(_map, _key), do: nil

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp stringify(value), do: value

  defp ascii?(value), do: Enum.all?(:binary.bin_to_list(value), &(&1 < 128))

  defp ascii_lower(value) do
    for <<byte <- value>>, into: <<>> do
      if byte >= ?A and byte <= ?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end

  defp trim_ascii_whitespace(value) do
    value
    |> trim_ascii_leading()
    |> trim_ascii_trailing()
  end

  defp trim_ascii_leading(<<byte, rest::binary>>) when byte in [9, 10, 13, 32],
    do: trim_ascii_leading(rest)

  defp trim_ascii_leading(value), do: value

  defp trim_ascii_trailing(<<>>), do: <<>>

  defp trim_ascii_trailing(value) do
    if :binary.last(value) in [9, 10, 13, 32],
      do: trim_ascii_trailing(binary_part(value, 0, byte_size(value) - 1)),
      else: value
  end

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
