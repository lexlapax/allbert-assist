defmodule AllbertAssist.Mcp.Registry.Official do
  @moduledoc """
  Adapter for the official MCP registry REST API.

  Current registry documentation exposes `GET /v0.1/servers` with cursor
  pagination and no server-side search parameter, so this adapter fetches a
  bounded page window and applies query matching locally.
  """

  @behaviour AllbertAssist.Mcp.Registry.Provider

  alias AllbertAssist.Maps
  alias AllbertAssist.Mcp.Registry.Http
  alias AllbertAssist.Validation

  @default_base_url "https://registry.modelcontextprotocol.io"
  @default_limit 25
  @max_limit 100
  @default_max_pages 2

  @impl true
  def provider_id, do: :official

  @impl true
  def search(query, opts \\ %{}) when is_map(opts) do
    query = to_string(query || "")
    limit = limit(opts)

    with {:ok, servers} <- fetch_pages(query, opts, limit) do
      servers
      |> Enum.map(&normalize_server/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&matches?(&1, query))
      |> Enum.sort_by(&rank_key(&1, query))
      |> Enum.take(limit)
      |> then(&{:ok, &1})
    end
  end

  @impl true
  def fetch_manifest(%{"manifest" => manifest}, _opts) when is_map(manifest), do: {:ok, manifest}
  def fetch_manifest(%{manifest: manifest}, _opts) when is_map(manifest), do: {:ok, manifest}

  def fetch_manifest(ref, opts) when is_map(ref) do
    cond do
      server_json?(ref) ->
        {:ok, ref}

      manifest_url = Maps.get_any(ref, ["manifest_url", :manifest_url, "url", :url]) ->
        fetch_manifest(manifest_url, opts)

      true ->
        {:error, :missing_manifest_ref}
    end
  end

  def fetch_manifest(url, opts) when is_binary(url) do
    Http.get_json(url, %{}, opts)
  end

  def fetch_manifest(_ref, _opts), do: {:error, :invalid_manifest_ref}

  defp fetch_pages(query, opts, limit) do
    do_fetch_pages(query, opts, limit, nil, max_pages(opts), [])
  end

  defp do_fetch_pages(_query, _opts, _limit, _cursor, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp do_fetch_pages(query, opts, limit, cursor, pages_left, acc) do
    params =
      %{"limit" => page_limit(limit)}
      |> maybe_put("cursor", cursor)
      |> maybe_put("updated_since", Maps.get_any(opts, [:updated_since, "updated_since"]))

    url = Http.join_url(base_url(opts), "/v0.1/servers")

    with {:ok, response} <- Http.get_json(url, params, opts) do
      servers = list_value(Maps.get_any(response, ["servers", :servers]))

      next_cursor =
        get_in(response, ["metadata", "nextCursor"]) || get_in(response, [:metadata, :nextCursor])

      acc = Enum.reverse(servers) ++ acc

      if next_cursor && Enum.count(acc, &matches_raw?(&1, query)) < limit do
        do_fetch_pages(query, opts, limit, next_cursor, pages_left - 1, acc)
      else
        {:ok, Enum.reverse(acc)}
      end
    end
  end

  defp normalize_server(server) when is_map(server) do
    server_id = Maps.get_any(server, ["name", :name, "id", :id])

    if present?(server_id) do
      %{
        provider: :official,
        remote_server_id: to_string(server_id),
        name: to_string(server_id),
        description: string_value(Maps.get_any(server, ["description", :description])),
        manifest: server,
        manifest_url: Maps.get_any(server, ["manifest_url", :manifest_url]),
        repository_url: repository_url(server),
        server_url: first_remote_url(server),
        version: Maps.get_any(server, ["version", :version]),
        updated_at: Maps.get_any(server, ["updated_at", :updated_at, "updatedAt", :updatedAt]),
        packages: package_summaries(server),
        transport_kinds: transport_kinds(server),
        signals: %{
          package_count: length(list_value(Maps.get_any(server, ["packages", :packages]))),
          repository_source:
            get_in(server, ["repository", "source"]) || get_in(server, [:repository, :source])
        }
      }
    end
  end

  defp normalize_server(_server), do: nil

  defp matches?(result, query) do
    query_tokens = tokens(query)
    text_tokens = result |> searchable_text() |> tokens()

    query_tokens == [] or Enum.all?(query_tokens, &(&1 in text_tokens))
  end

  defp matches_raw?(server, query) when is_map(server) do
    query_tokens = tokens(query)
    text_tokens = server |> normalize_server() |> searchable_text() |> tokens()

    query_tokens == [] or Enum.all?(query_tokens, &(&1 in text_tokens))
  end

  defp matches_raw?(_server, _query), do: false

  defp searchable_text(nil), do: ""

  defp searchable_text(result) do
    [
      result.name,
      result.description,
      result.repository_url,
      result.version,
      inspect(result.packages),
      inspect(result.transport_kinds)
    ]
    |> Enum.join(" ")
  end

  defp rank_key(result, query) do
    normalized_query = normalize(query)
    normalized_name = normalize(result.name)
    normalized_description = normalize(result.description)

    match_score =
      cond do
        normalized_query == "" -> 50
        normalized_name == normalized_query -> 0
        String.contains?(normalized_name, normalized_query) -> 10
        String.contains?(normalized_description, normalized_query) -> 20
        true -> 40
      end

    provenance_score = if present?(result.repository_url), do: 0, else: 10
    {match_score, provenance_score, normalized_name}
  end

  defp package_summaries(server) do
    server
    |> Maps.get_any(["packages", :packages])
    |> list_value()
    |> Enum.map(fn package ->
      %{
        registry_type:
          Maps.get_any(package, ["registryType", :registryType, "registry_type", :registry_type]),
        identifier: Maps.get_any(package, ["identifier", :identifier]),
        version: Maps.get_any(package, ["version", :version]),
        transport: get_in(package, ["transport", "type"]) || get_in(package, [:transport, :type])
      }
    end)
  end

  defp transport_kinds(server) do
    server
    |> package_summaries()
    |> Enum.map(& &1.transport)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp repository_url(server) do
    get_in(server, ["repository", "url"]) ||
      get_in(server, [:repository, :url]) ||
      Maps.get_any(server, [
        "repository_url",
        :repository_url,
        "source_code_url",
        :source_code_url
      ])
  end

  defp first_remote_url(server) do
    server
    |> Maps.get_any(["packages", :packages])
    |> list_value()
    |> Enum.find_value(fn package ->
      transport = Maps.get_any(package, ["transport", :transport]) || %{}

      Maps.get_any(transport, [
        "url",
        :url,
        "endpoint",
        :endpoint,
        "base_url",
        :base_url,
        "baseUrl",
        :baseUrl
      ])
    end)
  end

  defp server_json?(ref),
    do:
      present?(Maps.get_any(ref, ["name", :name])) and
        is_list(Maps.get_any(ref, ["packages", :packages]))

  defp base_url(opts), do: Maps.field(opts, :base_url, @default_base_url)

  defp limit(opts) do
    opts
    |> Maps.field(:limit, @default_limit)
    |> Validation.clamp_limit(@default_limit, @max_limit)
  end

  defp page_limit(limit),
    do: Validation.clamp_limit(limit * 2, @default_limit, @max_limit, @default_limit)

  defp max_pages(opts) do
    case Map.get(opts, :max_pages, Map.get(opts, "max_pages", @default_max_pages)) do
      value when is_integer(value) and value > 0 -> value
      _value -> @default_max_pages
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp string_value(nil), do: ""
  defp string_value(value) when is_binary(value), do: String.trim(value)
  defp string_value(value), do: value |> to_string() |> String.trim()

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp tokens(value) do
    value
    |> normalize()
    |> String.split(" ", trim: true)
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end
end
