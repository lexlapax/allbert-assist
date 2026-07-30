defmodule AllbertAssist.Search.Cursor do
  @moduledoc """
  Opaque authenticated schema-1 pagination cursor for conversation Search.

  Payloads contain generation/revision and the last scanned total-order
  position, but no query text, MATCH syntax, filter operands, or plain digest.
  The exact transient request and scope are rebound through Key Custody HMAC.
  """

  alias AllbertAssist.Search.Query
  alias AllbertAssist.Settings.KeyCustody

  @prefix "allbert.search.cursor.v1:"
  @domain "allbert.search.cursor.v1"
  @key_version 1

  @type decoded :: %{
          generation_id: String.t(),
          projection_revision: non_neg_integer(),
          order: atom(),
          position: map(),
          query_chain_id: String.t() | nil,
          expires_at: integer() | nil
        }

  @doc "Encode a cursor bound to one exact request, scope, generation, and revision."
  def encode(%Query{} = query, scope, generation_id, revision, position, opts \\ []) do
    chain_id = Keyword.get(opts, :query_chain_id, query.query_chain_id)
    expires_at = Keyword.get(opts, :expires_at)

    payload = %{
      "g" => generation_id,
      "r" => revision,
      "o" => Atom.to_string(query.order),
      "p" => string_keys(position),
      "k" => "secret://system/integrity_v1",
      "v" => @key_version,
      "c" => chain_id,
      "e" => expires_at
    }

    payload_bytes = Jason.encode!(payload)

    with {:ok, custody} <-
           KeyCustody.system_hmac(@domain, binding_fields(query, scope, payload), @key_version) do
      {:ok,
       @prefix <>
         Base.url_encode64(payload_bytes, padding: false) <>
         "." <> Base.url_encode64(custody.tag, padding: false)}
    end
  end

  @doc "Decode and authenticate a cursor against the exact transient request and scope."
  def decode(cursor, %Query{} = query, scope) when is_binary(cursor) do
    with true <- String.starts_with?(cursor, @prefix),
         encoded <- String.replace_prefix(cursor, @prefix, ""),
         [payload64, tag64] <- String.split(encoded, ".", parts: 2),
         {:ok, payload_bytes} <- Base.url_decode64(payload64, padding: false),
         {:ok, tag} <- Base.url_decode64(tag64, padding: false),
         {:ok, payload} <- Jason.decode(payload_bytes),
         :ok <- validate_payload(payload),
         {:ok, true} <-
           KeyCustody.verify_system_hmac(
             @domain,
             binding_fields(query, scope, payload),
             tag,
             payload["k"],
             payload["v"]
           ),
         {:ok, order} <- order(payload["o"]),
         {:ok, position} <- position(payload["p"], order) do
      {:ok,
       %{
         generation_id: payload["g"],
         projection_revision: payload["r"],
         order: order,
         position: position,
         query_chain_id: payload["c"],
         expires_at: payload["e"]
       }}
    else
      _other -> {:error, :invalid_query}
    end
  end

  def decode(_cursor, _query, _scope), do: {:error, :invalid_query}

  defp binding_fields(query, scope, payload) do
    [
      query.query,
      Atom.to_string(query.order),
      Integer.to_string(query.limit),
      canonical_filters(query.filters),
      canonical_scope(scope),
      payload["g"],
      Integer.to_string(payload["r"]),
      Jason.encode!(payload["p"]),
      payload["c"] || "",
      encode_optional_integer(payload["e"])
    ]
  end

  defp canonical_filters(filters) do
    filters
    |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
    |> Enum.map(fn {key, value} -> [Atom.to_string(key), canonical_value(value)] end)
    |> Jason.encode!()
  end

  defp canonical_scope(scope) do
    scope
    |> Enum.map(fn {key, value} -> [to_string(key), canonical_value(value)] end)
    |> Enum.sort()
    |> Jason.encode!()
  end

  defp canonical_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp canonical_value(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)

  defp canonical_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> [to_string(key), canonical_value(nested)] end)
    |> Enum.sort()
  end

  defp canonical_value(value), do: value

  defp validate_payload(%{
         "g" => generation_id,
         "r" => revision,
         "o" => order,
         "p" => position,
         "k" => "secret://system/integrity_v1",
         "v" => @key_version
       })
       when is_binary(generation_id) and is_integer(revision) and revision >= 0 and
              is_binary(order) and is_map(position),
       do: :ok

  defp validate_payload(_payload), do: {:error, :invalid_cursor}

  defp order("relevance"), do: {:ok, :relevance}
  defp order("newest"), do: {:ok, :newest}
  defp order("oldest"), do: {:ok, :oldest}
  defp order(_order), do: {:error, :invalid_cursor}

  defp position(payload, :relevance) do
    with score when is_number(score) <- payload["score"],
         timestamp when is_integer(timestamp) <- payload["timestamp_us"],
         source_id when is_binary(source_id) <- payload["source_id"] do
      {:ok, %{score: score, timestamp_us: timestamp, source_id: source_id}}
    else
      _other -> {:error, :invalid_cursor}
    end
  end

  defp position(payload, _order) do
    with timestamp when is_integer(timestamp) <- payload["timestamp_us"],
         source_id when is_binary(source_id) <- payload["source_id"] do
      {:ok, %{timestamp_us: timestamp, source_id: source_id}}
    else
      _other -> {:error, :invalid_cursor}
    end
  end

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp encode_optional_integer(nil), do: ""
  defp encode_optional_integer(value) when is_integer(value), do: Integer.to_string(value)
end
