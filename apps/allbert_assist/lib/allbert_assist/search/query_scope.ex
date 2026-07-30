defmodule AllbertAssist.Search.QueryScope do
  @moduledoc """
  Keyed one-query authorization binding for mapped-DM cross-surface Search.

  There is no grant store. The resolved confirmation record is the query-chain
  authority, while query text and filter operands remain transient and must be
  resubmitted for verification.
  """

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Search.Query
  alias AllbertAssist.Settings.KeyCustody

  @domain "allbert.search.query-scope.v1"
  @key_version 1
  @ttl_seconds 300
  @target_action "authorize_search_query_scope"

  @doc "Build the safe confirmation binding for one exact transient request."
  def bind(%Query{} = query, context) when is_map(context) do
    expires_at = System.system_time(:second) + @ttl_seconds

    with {:ok, scope} <- mapped_scope(context),
         {:ok, custody} <-
           KeyCustody.system_hmac(@domain, fields(query, scope, expires_at), @key_version) do
      {:ok,
       scope
       |> Map.merge(%{
         requested_scope: "cross_surface",
         expires_at: expires_at,
         filter_kinds: query.filters |> Map.keys() |> Enum.sort() |> Enum.map(&Atom.to_string/1),
         filter_count: map_size(query.filters),
         request_binding: Base.url_encode64(custody.tag, padding: false),
         key_ref: custody.key_ref,
         key_version: custody.key_version
       })}
    end
  end

  @doc "Verify one approved confirmation against the exact resubmitted request and live origin."
  def verify(query_chain_id, %Query{} = query, context)
      when is_binary(query_chain_id) and is_map(context) do
    with {:ok, record} <- Confirmations.read(query_chain_id),
         :ok <- approved_search_record(record),
         safe when is_map(safe) <- Map.get(record, "resume_params_ref", %{}),
         :ok <- not_expired(safe),
         {:ok, current_scope} <- mapped_scope(context),
         :ok <- same_scope(safe, current_scope),
         {:ok, tag} <- decode_binding(safe),
         {:ok, true} <-
           KeyCustody.verify_system_hmac(
             @domain,
             fields(query, current_scope, field(safe, "expires_at")),
             tag,
             field(safe, "key_ref"),
             field(safe, "key_version")
           ),
         :ok <- source_current(safe, current_scope) do
      {:ok,
       %{
         query_chain_id: query_chain_id,
         expires_at: field(safe, "expires_at"),
         scope: current_scope
       }}
    else
      {:ok, false} -> {:error, :scope_denied}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :scope_denied}
    end
  end

  def verify(_query_chain_id, _query, _context), do: {:error, :scope_denied}

  defp approved_search_record(record) do
    cond do
      record["status"] != "approved" -> {:error, :query_confirmation_required}
      get_in(record, ["target_action", "name"]) != @target_action -> {:error, :scope_denied}
      true -> :ok
    end
  end

  defp mapped_scope(context) do
    operator_id = field(context, "operator_id") || field(context, "user_id")
    thread_id = field(context, "thread_id")
    source_message_id = field(context, "source_message_id")
    origin = field(context, "origin")

    if present?(operator_id) and present?(thread_id) and present?(source_message_id) and
         valid_origin?(origin) do
      {:ok,
       %{
         operator_id: operator_id,
         thread_id: thread_id,
         source_message_id: source_message_id,
         origin: atomize_origin(origin)
       }}
    else
      {:error, :scope_denied}
    end
  end

  defp source_current(safe, scope) do
    ref = field(safe, "source_message_id")

    case Corpus.rehydrate_and_authorize(
           scope.operator_id,
           [ref],
           %{
             consumer: :search,
             origin_scope: :mapped_operator_dm,
             e2ee?: false,
             thread_id: scope.thread_id,
             origin: scope.origin
           }
         ) do
      {:ok, [{:ok, _envelope}]} -> :ok
      {:ok, [{:error, _reason}]} -> {:error, :scope_denied}
      {:error, _reason} -> {:error, :scope_denied}
    end
  end

  defp fields(query, scope, expires_at) do
    [
      query.query,
      Atom.to_string(query.order),
      Integer.to_string(query.limit),
      canonical_filters(query.filters),
      scope.operator_id,
      scope.thread_id,
      scope.source_message_id,
      canonical_origin(scope.origin),
      "cross_surface",
      Integer.to_string(expires_at)
    ]
  end

  defp canonical_filters(filters) do
    filters
    |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
    |> Enum.map(fn {key, value} -> [Atom.to_string(key), canonical_value(value)] end)
    |> Jason.encode!()
  end

  defp canonical_origin(origin) do
    ~w[owner_scope channel receiver_account_ref provider_thread_key]a
    |> Enum.map(fn key -> [Atom.to_string(key), Map.fetch!(origin, key)] end)
    |> Jason.encode!()
  end

  defp canonical_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp canonical_value(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value), do: value

  defp same_scope(safe, scope) do
    expected = %{
      "operator_id" => scope.operator_id,
      "thread_id" => scope.thread_id,
      "source_message_id" => scope.source_message_id,
      "origin" => Map.new(scope.origin, fn {key, value} -> {Atom.to_string(key), value} end)
    }

    actual = Map.take(string_keys(safe), Map.keys(expected))
    if actual == expected, do: :ok, else: {:error, :scope_denied}
  end

  defp not_expired(safe) do
    case field(safe, "expires_at") do
      value when is_integer(value) ->
        if System.system_time(:second) < value,
          do: :ok,
          else: {:error, :query_chain_expired}

      _other ->
        {:error, :query_chain_expired}
    end
  end

  defp decode_binding(safe) do
    case field(safe, "request_binding") do
      value when is_binary(value) ->
        case Base.url_decode64(value, padding: false) do
          {:ok, tag} when byte_size(tag) == 32 -> {:ok, tag}
          _other -> {:error, :scope_denied}
        end

      _other ->
        {:error, :scope_denied}
    end
  end

  defp valid_origin?(origin) when is_map(origin) do
    Enum.all?(~w[owner_scope channel receiver_account_ref provider_thread_key]a, fn key ->
      present?(field(origin, Atom.to_string(key)))
    end)
  end

  defp valid_origin?(_origin), do: false

  defp atomize_origin(origin) do
    Map.new(~w[owner_scope channel receiver_account_ref provider_thread_key]a, fn key ->
      {key, field(origin, Atom.to_string(key))}
    end)
  end

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp field(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp field(_map, _key), do: nil
  defp present?(value), do: is_binary(value) and value != ""
end
