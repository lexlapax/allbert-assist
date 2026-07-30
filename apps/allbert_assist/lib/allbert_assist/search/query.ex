defmodule AllbertAssist.Search.Query do
  @moduledoc """
  Closed, bounded parser for the v1.3 conversation-search request contract.

  The parser emits parameterized FTS5 MATCH syntax. It never accepts raw FTS
  operators, column selectors, parentheses, or caller-authored MATCH text.
  """

  @orders [:relevance, :newest, :oldest]
  @authors [:operator, :assistant]
  @origin_scopes [:local_operator, :mapped_operator_dm]
  @request_keys ~w[query order limit cursor filters query_chain_id]
  @filter_keys ~w[authors surfaces thread_ids after before origin_scope e2ee]
  @max_query_bytes 1_024
  @max_clauses 16
  @max_phrase_tokens 12
  @max_list_values 8
  @max_filter_count 8
  @default_limit 20
  @max_limit 100
  @reserved_operators ~w[and or not near]

  @enforce_keys [:query, :match, :clauses, :order, :limit, :filters]
  defstruct schema_version: 1,
            query: nil,
            match: nil,
            clauses: [],
            order: :relevance,
            limit: @default_limit,
            cursor: nil,
            filters: %{},
            query_chain_id: nil

  @type clause :: {:term, String.t()} | {:phrase, [String.t()]} | {:prefix, String.t()}
  @type t :: %__MODULE__{}

  @doc "Validate and normalize one schema-1 Search request."
  @spec parse(map()) :: {:ok, t()} | {:error, atom()}
  def parse(request) when is_map(request) do
    with :ok <- closed_keys(request, @request_keys, :invalid_query),
         {:ok, query} <- required_binary(request, "query", @max_query_bytes, :invalid_query),
         {:ok, clauses} <- parse_clauses(query),
         {:ok, order} <- enum_value(request, "order", :relevance, @orders, :invalid_query),
         {:ok, limit} <- limit(request),
         {:ok, cursor} <- optional_binary(request, "cursor", 4_096, :invalid_query),
         {:ok, chain_id} <- optional_binary(request, "query_chain_id", 128, :invalid_query),
         {:ok, filters} <- filters(value(request, "filters", %{})) do
      {:ok,
       %__MODULE__{
         query: query,
         match: encode_match(clauses),
         clauses: clauses,
         order: order,
         limit: limit,
         cursor: cursor,
         filters: filters,
         query_chain_id: chain_id
       }}
    end
  end

  def parse(_request), do: {:error, :invalid_query}

  @doc "Return a content-free summary suitable for signals and durable logs."
  def trace_summary(%__MODULE__{} = query) do
    %{
      schema_version: query.schema_version,
      order: query.order,
      limit: query.limit,
      clause_count: length(query.clauses),
      filter_kinds: query.filters |> Map.keys() |> Enum.sort(),
      filter_count: map_size(query.filters),
      cursor?: is_binary(query.cursor),
      query_chain_id: query.query_chain_id
    }
  end

  defp parse_clauses(query) do
    if String.valid?(query) and byte_size(query) <= @max_query_bytes do
      query
      |> String.trim()
      |> scan_clauses([], 0)
    else
      {:error, :invalid_query}
    end
  end

  defp scan_clauses("", [], _phrase_count), do: {:error, :invalid_query}
  defp scan_clauses("", clauses, _phrase_count), do: {:ok, Enum.reverse(clauses)}

  defp scan_clauses(rest, clauses, _phrase_count) when length(clauses) >= @max_clauses do
    if String.trim(rest) == "", do: {:ok, Enum.reverse(clauses)}, else: {:error, :invalid_query}
  end

  defp scan_clauses(rest, clauses, phrase_count) do
    rest = String.trim_leading(rest)

    cond do
      rest == "" ->
        scan_clauses("", clauses, phrase_count)

      String.starts_with?(rest, "\"") ->
        scan_phrase(rest, clauses, phrase_count)

      true ->
        scan_word(rest, clauses, phrase_count)
    end
  end

  defp scan_phrase(_rest, _clauses, phrase_count) when phrase_count >= 1,
    do: {:error, :invalid_query}

  defp scan_phrase(<<?\", rest::binary>>, clauses, phrase_count) do
    case :binary.match(rest, "\"") do
      {index, 1} ->
        phrase = binary_part(rest, 0, index)
        tail = binary_part(rest, index + 1, byte_size(rest) - index - 1)

        with {:ok, words} <- phrase_words(phrase),
             :ok <- separator_or_end(tail) do
          scan_clauses(tail, [{:phrase, words} | clauses], phrase_count + 1)
        end

      :nomatch ->
        {:error, :invalid_query}
    end
  end

  defp scan_word(rest, clauses, phrase_count) do
    case Regex.run(~r/\A([\p{L}\p{N}\p{M}]+)(\*)?/u, rest) do
      [matched, word, prefix] ->
        continue_word(rest, matched, word, prefix, clauses, phrase_count)

      [matched, word] ->
        continue_word(rest, matched, word, nil, clauses, phrase_count)

      _other ->
        {:error, :invalid_query}
    end
  end

  defp continue_word(rest, matched, word, prefix, clauses, phrase_count) do
    tail = binary_part(rest, byte_size(matched), byte_size(rest) - byte_size(matched))

    with :ok <- reject_reserved_operator(word),
         :ok <- separator_or_end(tail),
         :ok <- valid_prefix(word, prefix) do
      kind = if prefix == "*", do: :prefix, else: :term
      scan_clauses(tail, [{kind, word} | clauses], phrase_count)
    end
  end

  defp phrase_words(phrase) do
    words = String.split(phrase, ~r/\s+/u, trim: true)

    if words != [] and length(words) <= @max_phrase_tokens and
         Enum.all?(words, &Regex.match?(~r/\A[\p{L}\p{N}\p{M}]+\z/u, &1)) do
      {:ok, words}
    else
      {:error, :invalid_query}
    end
  end

  defp separator_or_end(""), do: :ok

  defp separator_or_end(rest) do
    if Regex.match?(~r/\A\s/u, rest), do: :ok, else: {:error, :invalid_query}
  end

  defp valid_prefix(word, "*") do
    if String.length(word) >= 2, do: :ok, else: {:error, :invalid_query}
  end

  defp valid_prefix(_word, _none), do: :ok

  defp reject_reserved_operator(word) do
    if String.downcase(word) in @reserved_operators,
      do: {:error, :invalid_query},
      else: :ok
  end

  defp encode_match(clauses) do
    Enum.map_join(clauses, " ", fn
      {:term, word} -> "\"#{word}\""
      {:prefix, word} -> "\"#{word}\"*"
      {:phrase, words} -> "\"#{Enum.join(words, " ")}\""
    end)
  end

  defp filters(filters) when is_map(filters) and map_size(filters) <= @max_filter_count do
    with :ok <- closed_keys(filters, @filter_keys, :invalid_filter),
         {:ok, authors} <- enum_list(filters, "authors", @authors),
         {:ok, surfaces} <- string_list(filters, "surfaces", 64),
         {:ok, thread_ids} <- string_list(filters, "thread_ids", 128),
         {:ok, after_at} <- timestamp(filters, "after"),
         {:ok, before_at} <- timestamp(filters, "before"),
         :ok <- timestamp_order(after_at, before_at),
         {:ok, origin_scope} <- optional_enum(filters, "origin_scope", @origin_scopes),
         {:ok, e2ee?} <- optional_boolean(filters, "e2ee") do
      {:ok,
       %{}
       |> put_present(:authors, authors)
       |> put_present(:surfaces, surfaces)
       |> put_present(:thread_ids, thread_ids)
       |> put_present(:after, after_at)
       |> put_present(:before, before_at)
       |> put_present(:origin_scope, origin_scope)
       |> put_present(:e2ee, e2ee?)}
    end
  end

  defp filters(_filters), do: {:error, :invalid_filter}

  defp enum_list(map, key, allowed) do
    case fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, values}
      when is_list(values) and values != [] and length(values) <= @max_list_values ->
        normalize_enum_list(values, allowed)

      _other ->
        {:error, :invalid_filter}
    end
  end

  defp normalize_enum_list(values, allowed) do
    normalized = Enum.map(values, &normalize_enum(&1, allowed))

    if Enum.all?(normalized, & &1),
      do: {:ok, Enum.uniq(normalized)},
      else: {:error, :invalid_filter}
  end

  defp string_list(map, key, max_bytes) do
    case fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, values}
      when is_list(values) and values != [] and length(values) <= @max_list_values ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "" and byte_size(&1) <= max_bytes)),
          do: {:ok, Enum.uniq(values)},
          else: {:error, :invalid_filter}

      _other ->
        {:error, :invalid_filter}
    end
  end

  defp timestamp(map, key) do
    case fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, %DateTime{} = value} -> {:ok, DateTime.truncate(value, :microsecond)}
      {:ok, value} when is_binary(value) -> parse_timestamp(value)
      _other -> {:error, :invalid_filter}
    end
  end

  defp parse_timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _error -> {:error, :invalid_filter}
    end
  end

  defp timestamp_order(nil, _before), do: :ok
  defp timestamp_order(_after, nil), do: :ok

  defp timestamp_order(after_at, before_at) do
    if DateTime.compare(after_at, before_at) == :lt,
      do: :ok,
      else: {:error, :invalid_filter}
  end

  defp optional_enum(map, key, allowed) do
    case fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        case normalize_enum(value, allowed) do
          nil -> {:error, :invalid_filter}
          normalized -> {:ok, normalized}
        end
    end
  end

  defp optional_boolean(map, key) do
    case fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _other -> {:error, :invalid_filter}
    end
  end

  defp limit(request) do
    case value(request, "limit", @default_limit) do
      value when is_integer(value) and value >= 1 and value <= @max_limit -> {:ok, value}
      _other -> {:error, :invalid_limit}
    end
  end

  defp enum_value(map, key, default, allowed, error) do
    case normalize_enum(value(map, key, default), allowed) do
      nil -> {:error, error}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_enum(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp normalize_enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp normalize_enum(_value, _allowed), do: nil

  defp required_binary(map, key, max_bytes, error) do
    case fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" and byte_size(value) <= max_bytes ->
        {:ok, value}

      _other ->
        {:error, error}
    end
  end

  defp optional_binary(map, key, max_bytes, error) do
    case fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) and value != "" and byte_size(value) <= max_bytes ->
        {:ok, value}

      _other ->
        {:error, error}
    end
  end

  defp closed_keys(map, allowed, error) do
    if Enum.all?(Map.keys(map), &(to_string(&1) in allowed)), do: :ok, else: {:error, error}
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, String.to_atom(key))
    end
  end

  defp value(map, key, default),
    do:
      case(fetch(map, key),
        do: (
          {:ok, value} -> value
          :error -> default
        )
      )

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
