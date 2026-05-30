defmodule AllbertAssist.Mcp.Registry.PulseMcp do
  @moduledoc """
  Adapter for the optional PulseMCP registry source.

  PulseMCP's public beta API is currently unauthenticated. Allbert still honors
  the v0.42 settings contract: if the Pulse source is enabled, configured MCP
  secret refs must be present before the source is queried.
  """

  @behaviour AllbertAssist.Mcp.Registry.Provider

  alias AllbertAssist.Mcp.Registry.Http
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store

  @default_base_url "https://api.pulsemcp.com/v0beta"
  @default_limit 25
  @max_limit 100

  @impl true
  def provider_id, do: :pulsemcp

  @impl true
  def search(query, opts \\ %{}) when is_map(opts) do
    with :ok <- maybe_require_configured_secrets(opts),
         {:ok, response} <- fetch_servers(query, opts) do
      limit = limit(opts)

      response
      |> Map.get("servers", Map.get(response, :servers, []))
      |> list_value()
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
  def fetch_manifest(ref, _opts) when is_map(ref), do: {:ok, ref}
  def fetch_manifest(url, opts) when is_binary(url), do: Http.get_json(url, %{}, opts)
  def fetch_manifest(_ref, _opts), do: {:error, :invalid_manifest_ref}

  @doc "Return whether the optional PulseMCP source can be queried now."
  def configured_status do
    enabled? = raw_setting("mcp.discovery.sources.pulsemcp.enabled", false)
    api_key_ref = raw_setting("mcp.discovery.sources.pulsemcp.api_key_ref", nil)
    tenant_ref = raw_setting("mcp.discovery.sources.pulsemcp.tenant_ref", nil)

    cond do
      enabled? != true ->
        :disabled

      not is_binary(api_key_ref) or not is_binary(tenant_ref) ->
        :missing_secret_refs

      Secrets.status(api_key_ref) != :configured ->
        {:missing_secret, api_key_ref}

      Secrets.status(tenant_ref) != :configured ->
        {:missing_secret, tenant_ref}

      true ->
        :ok
    end
  end

  defp maybe_require_configured_secrets(opts) do
    if Map.get(
         opts,
         :require_configured_secrets?,
         Map.get(opts, "require_configured_secrets?", true)
       ) do
      case configured_status() do
        :ok -> :ok
        status -> {:error, status}
      end
    else
      :ok
    end
  end

  defp fetch_servers(query, opts) do
    params = %{
      "query" => to_string(query || ""),
      "count_per_page" => limit(opts),
      "offset" => Map.get(opts, :offset, Map.get(opts, "offset", 0))
    }

    headers = [{"user-agent", "AllbertAssist/0.42 MCP discovery"}]

    opts =
      opts
      |> Map.put_new(:headers, headers)
      |> Map.put_new("headers", headers)

    Http.get_json(Http.join_url(base_url(opts), "/servers"), params, opts)
  end

  defp normalize_server(server) when is_map(server) do
    name = get_any(server, ["name", :name])

    if present?(name) do
      %{
        provider: :pulsemcp,
        remote_server_id: to_string(name),
        name: to_string(name),
        description: description(server),
        manifest: server,
        manifest_url: nil,
        repository_url: get_any(server, ["source_code_url", :source_code_url]),
        server_url: first_remote_url(server) || get_any(server, ["url", :url]),
        version: nil,
        updated_at: get_any(server, ["updated_at", :updated_at]),
        packages: package_summaries(server),
        transport_kinds: transport_kinds(server),
        signals: %{
          github_stars: int_value(get_any(server, ["github_stars", :github_stars])),
          package_download_count:
            int_value(get_any(server, ["package_download_count", :package_download_count])),
          total_count: int_value(get_any(server, ["total_count", :total_count]))
        }
      }
    end
  end

  defp normalize_server(_server), do: nil

  defp description(server) do
    get_any(server, [
      "short_description",
      :short_description,
      "description",
      :description,
      "EXPERIMENTAL_ai_generated_description",
      :EXPERIMENTAL_ai_generated_description
    ])
    |> string_value()
  end

  defp package_summaries(server) do
    case get_any(server, ["package_name", :package_name]) do
      value when is_binary(value) and value != "" ->
        [
          %{
            registry_type: get_any(server, ["package_registry", :package_registry]),
            identifier: value,
            version: nil,
            transport: nil
          }
        ]

      _value ->
        []
    end
  end

  defp transport_kinds(server) do
    server
    |> get_any(["remotes", :remotes])
    |> list_value()
    |> Enum.map(&get_any(&1, ["transport", :transport]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp first_remote_url(server) do
    server
    |> get_any(["remotes", :remotes])
    |> list_value()
    |> Enum.find_value(fn remote ->
      get_any(remote, ["url_direct", :url_direct, "direct_url", :direct_url])
    end)
  end

  defp matches?(result, query) do
    query_tokens = tokens(query)
    text_tokens = result |> searchable_text() |> tokens()

    query_tokens == [] or Enum.all?(query_tokens, &(&1 in text_tokens))
  end

  defp searchable_text(result) do
    [
      result.name,
      result.description,
      result.repository_url,
      result.server_url,
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

    popularity_score =
      -1 * max(result.signals.github_stars || 0, result.signals.package_download_count || 0)

    {match_score, popularity_score, normalized_name}
  end

  defp raw_setting(key, default) do
    case Store.resolved_settings() do
      {:ok, settings, _user_settings} -> get_dotted(settings, key) || default
      {:error, _reason} -> default
    end
  end

  defp get_dotted(settings, key) do
    settings
    |> get_in(String.split(key, "."))
  end

  defp base_url(opts), do: Map.get(opts, :base_url, Map.get(opts, "base_url", @default_base_url))

  defp limit(opts) do
    case Map.get(opts, :limit, Map.get(opts, "limit", @default_limit)) do
      value when is_integer(value) and value > 0 -> min(value, @max_limit)
      _value -> @default_limit
    end
  end

  defp get_any(nil, _keys), do: nil

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp get_any(_value, _keys), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp int_value(value) when is_integer(value), do: value
  defp int_value(value) when is_float(value), do: round(value)
  defp int_value(_value), do: 0

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
