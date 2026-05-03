defmodule AllbertAssist.External.RequestSpec do
  @moduledoc """
  Normalized, redacted request specification for confirmed external service calls.
  """

  alias AllbertAssist.External.HttpPolicy
  alias AllbertAssist.Settings

  @methods ~w(GET HEAD POST PUT PATCH DELETE)

  @enforce_keys [
    :method,
    :url,
    :uri,
    :profile,
    :host,
    :path,
    :headers,
    :timeout_ms,
    :max_response_bytes,
    :allow_redirects?,
    :max_redirects,
    :retry_policy,
    :redact_request_headers,
    :redact_response_headers
  ]
  defstruct [
    :method,
    :url,
    :uri,
    :profile,
    :host,
    :path,
    :query,
    :headers,
    :body,
    :body_summary,
    :timeout_ms,
    :max_response_bytes,
    :allow_redirects?,
    :max_redirects,
    :retry_policy,
    :redact_request_headers,
    :redact_response_headers,
    :source_text,
    :denial_reason,
    enabled?: false,
    profile_enabled?: false,
    allowed_hosts: [],
    blocked_hosts: [],
    allowed_paths: [],
    allowed_methods: []
  ]

  @type t :: %__MODULE__{
          method: String.t(),
          url: String.t(),
          uri: URI.t(),
          profile: String.t(),
          host: String.t(),
          path: String.t(),
          query: nil | String.t(),
          headers: [{String.t(), String.t()}],
          body: nil | String.t(),
          body_summary: map(),
          timeout_ms: pos_integer(),
          max_response_bytes: pos_integer(),
          allow_redirects?: boolean(),
          max_redirects: non_neg_integer(),
          retry_policy: String.t(),
          redact_request_headers: [String.t()],
          redact_response_headers: [String.t()],
          source_text: nil | String.t(),
          denial_reason: nil | atom() | tuple(),
          enabled?: boolean(),
          profile_enabled?: boolean(),
          allowed_hosts: [String.t()],
          blocked_hosts: [String.t()],
          allowed_paths: [String.t()],
          allowed_methods: [String.t()]
        }

  @spec normalize(map(), keyword()) :: {:ok, t()} | {:error, t()}
  def normalize(params, _opts \\ []) when is_map(params) do
    settings = external_settings()
    profile = string_value(params, :profile) || "default"
    profile_settings = profile_settings(settings, profile)

    with {:ok, merged} <- merge_profile(settings, profile, profile_settings),
         {:ok, method} <- normalize_method(value(params, :method) || "GET"),
         {:ok, url} <- normalize_url(params, profile, merged),
         {:ok, uri} <- parse_url(url),
         {:ok, headers} <- normalize_headers(value(params, :headers)),
         :ok <- reject_sensitive_request_headers(headers, merged),
         {:ok, timeout_ms} <-
           capped_integer(
             value(params, :timeout_ms),
             merged.default_timeout_ms,
             merged.max_timeout_ms
           ),
         {:ok, max_response_bytes} <-
           capped_integer(
             value(params, :max_response_bytes),
             merged.max_response_bytes,
             merged.max_response_bytes
           ),
         {:ok, body, body_summary} <- normalize_body(params) do
      spec =
        %__MODULE__{
          method: method,
          url: URI.to_string(uri),
          uri: uri,
          profile: profile,
          host: String.downcase(uri.host || ""),
          path: path(uri),
          query: uri.query,
          headers: headers,
          body: body,
          body_summary: body_summary,
          timeout_ms: timeout_ms,
          max_response_bytes: max_response_bytes,
          allow_redirects?: merged.allow_redirects?,
          max_redirects: merged.max_redirects,
          retry_policy: merged.retry_policy,
          redact_request_headers: merged.redact_request_headers,
          redact_response_headers: merged.redact_response_headers,
          source_text: string_value(params, :source_text),
          enabled?: merged.enabled?,
          profile_enabled?: merged.profile_enabled?,
          allowed_hosts: merged.allowed_hosts,
          blocked_hosts: merged.blocked_hosts,
          allowed_paths: merged.allowed_paths,
          allowed_methods: merged.allowed_methods
        }

      case HttpPolicy.validate(spec) do
        :ok -> {:ok, spec}
        {:error, reason} -> {:error, %{spec | denial_reason: reason}}
      end
    else
      {:error, reason} ->
        {:error, error_spec(params, settings, profile, reason)}
    end
  end

  def summary(%__MODULE__{} = spec) do
    %{
      method: spec.method,
      profile: spec.profile,
      url: redacted_url(spec),
      host: spec.host,
      path: spec.path,
      query?: is_binary(spec.query) and spec.query != "",
      headers: redact_headers(spec.headers, spec.redact_request_headers),
      body: spec.body_summary,
      timeout_ms: spec.timeout_ms,
      max_response_bytes: spec.max_response_bytes,
      allow_redirects?: spec.allow_redirects?,
      max_redirects: spec.max_redirects,
      retry_policy: spec.retry_policy,
      request_digest: digest(spec),
      denial_reason: spec.denial_reason
    }
  end

  @spec resume_params(t()) :: map()
  def resume_params(%__MODULE__{} = spec) do
    %{
      action: "external_network_request",
      method: spec.method,
      url: spec.url,
      profile: spec.profile,
      headers: Map.new(spec.headers),
      body: spec.body,
      timeout_ms: spec.timeout_ms,
      max_response_bytes: spec.max_response_bytes,
      source_text: spec.source_text
    }
  end

  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = spec) do
    spec
    |> Map.take([
      :method,
      :profile,
      :url,
      :headers,
      :body_summary,
      :timeout_ms,
      :max_response_bytes
    ])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec redacted_url(t()) :: String.t()
  def redacted_url(%__MODULE__{uri: uri}) do
    base = "#{uri.scheme}://#{uri.host}#{path(uri)}"

    if is_binary(uri.query) and uri.query != "" do
      "#{base}?[REDACTED]"
    else
      base
    end
  end

  @spec redact_headers([{String.t(), String.t()}], [String.t()]) :: [map()]
  def redact_headers(headers, redact_names) do
    redact_names = normalized_names(redact_names)

    Enum.map(headers, fn {name, value} ->
      value = if String.downcase(name) in redact_names, do: "[REDACTED]", else: value
      %{name: name, value: value}
    end)
  end

  defp external_settings do
    profiles = setting("external_services.profiles", %{})

    %{
      enabled?: setting("external_services.enabled", false),
      allowed_hosts: setting("external_services.allowed_hosts", []),
      blocked_hosts: setting("external_services.blocked_hosts", []),
      allowed_paths: setting("external_services.allowed_paths", ["/"]),
      allowed_methods: setting("external_services.allowed_methods", ["GET", "HEAD"]),
      default_timeout_ms: setting("external_services.default_timeout_ms", 5000),
      max_timeout_ms: setting("external_services.max_timeout_ms", 30_000),
      max_response_bytes: setting("external_services.max_response_bytes", 1_048_576),
      allow_redirects?: setting("external_services.allow_redirects", false),
      max_redirects: setting("external_services.max_redirects", 0),
      retry_policy: setting("external_services.retry_policy", "none"),
      redact_request_headers:
        setting("external_services.redact_request_headers", [
          "authorization",
          "cookie",
          "x-api-key"
        ]),
      redact_response_headers:
        setting("external_services.redact_response_headers", ["set-cookie", "authorization"]),
      profiles: profiles
    }
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp profile_settings(_settings, "default"), do: {:ok, %{}}

  defp profile_settings(settings, profile) do
    case Map.get(settings.profiles, profile) do
      attrs when is_map(attrs) -> {:ok, attrs}
      _other -> {:error, {:unknown_external_profile, profile}}
    end
  end

  defp merge_profile(_settings, _profile, {:error, reason}), do: {:error, reason}

  defp merge_profile(settings, profile, {:ok, attrs}) do
    profile_enabled? =
      if profile == "default" do
        true
      else
        Map.get(attrs, "enabled", false)
      end

    merged =
      settings
      |> Map.drop([:profiles])
      |> Map.merge(%{
        profile_enabled?: profile_enabled?,
        base_url: Map.get(attrs, "base_url"),
        allowed_hosts: Map.get(attrs, "allowed_hosts", settings.allowed_hosts),
        blocked_hosts: Map.get(attrs, "blocked_hosts", settings.blocked_hosts),
        allowed_paths: Map.get(attrs, "allowed_paths", settings.allowed_paths),
        allowed_methods: Map.get(attrs, "allowed_methods", settings.allowed_methods),
        default_timeout_ms: Map.get(attrs, "default_timeout_ms", settings.default_timeout_ms),
        max_timeout_ms: Map.get(attrs, "max_timeout_ms", settings.max_timeout_ms),
        max_response_bytes: Map.get(attrs, "max_response_bytes", settings.max_response_bytes),
        allow_redirects?: Map.get(attrs, "allow_redirects", settings.allow_redirects?),
        max_redirects: Map.get(attrs, "max_redirects", settings.max_redirects),
        retry_policy: Map.get(attrs, "retry_policy", settings.retry_policy),
        redact_request_headers:
          Map.get(attrs, "redact_request_headers", settings.redact_request_headers),
        redact_response_headers:
          Map.get(attrs, "redact_response_headers", settings.redact_response_headers)
      })

    {:ok, merged}
  end

  defp normalize_method(method) when is_binary(method) do
    method = method |> String.trim() |> String.upcase()
    if method in @methods, do: {:ok, method}, else: {:error, {:unsupported_method, method}}
  end

  defp normalize_method(method), do: {:error, {:unsupported_method, method}}

  defp normalize_url(params, _profile, merged) do
    url = string_value(params, :url) || request_url(params) || profile_url(params, merged)
    query = value(params, :query)

    with url when is_binary(url) <- url,
         {:ok, uri} <- parse_url(url),
         {:ok, query} <- normalize_query(query) do
      {:ok, URI.to_string(%{uri | query: merge_query(uri.query, query)})}
    else
      nil -> {:error, :missing_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_url(params) do
    request = string_value(params, :request)

    case request && Regex.run(~r/https?:\/\/[^\s<>"']+/i, request) do
      [url | _rest] -> url
      _other -> nil
    end
  end

  defp profile_url(params, %{base_url: base_url}) when is_binary(base_url) do
    path = string_value(params, :path) || "/"

    base_url
    |> URI.merge(path)
    |> URI.to_string()
  end

  defp profile_url(_params, _merged), do: nil

  defp parse_url(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    if is_binary(uri.host) do
      {:ok, uri}
    else
      {:error, :invalid_url}
    end
  end

  defp normalize_query(nil), do: {:ok, nil}
  defp normalize_query(query) when is_binary(query), do: {:ok, String.trim_leading(query, "?")}
  defp normalize_query(query) when is_map(query), do: {:ok, URI.encode_query(query)}
  defp normalize_query(query), do: {:error, {:invalid_query, query}}

  defp merge_query(nil, nil), do: nil
  defp merge_query(existing, nil), do: existing
  defp merge_query(nil, query), do: query
  defp merge_query(existing, query), do: "#{existing}&#{query}"

  defp normalize_headers(nil), do: {:ok, []}

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {name, value} -> {to_string(name), to_string(value)} end)
    |> normalize_headers()
  end

  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.reduce_while({:ok, []}, fn
      {name, value}, {:ok, acc} ->
        {:cont, {:ok, [{normalize_header_name(name), to_string(value)} | acc]}}

      %{"name" => name, "value" => value}, {:ok, acc} ->
        {:cont, {:ok, [{normalize_header_name(name), to_string(value)} | acc]}}

      %{name: name, value: value}, {:ok, acc} ->
        {:cont, {:ok, [{normalize_header_name(name), to_string(value)} | acc]}}

      other, {:ok, _acc} ->
        {:halt, {:error, {:invalid_header, other}}}
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_headers(headers), do: {:error, {:invalid_headers, headers}}

  defp normalize_header_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp reject_sensitive_request_headers(headers, merged) do
    redact_names = normalized_names(merged.redact_request_headers)

    Enum.find(headers, fn {name, _value} -> name in redact_names end)
    |> case do
      nil -> :ok
      {name, _value} -> {:error, {:sensitive_header_requires_secret_ref, name}}
    end
  end

  defp normalize_body(params) do
    cond do
      is_binary(value(params, :body)) ->
        body = value(params, :body)
        {:ok, body, %{type: "raw", bytes: byte_size(body), preview: preview(body)}}

      is_map(value(params, :json)) ->
        case Jason.encode(value(params, :json)) do
          {:ok, encoded} -> {:ok, encoded, %{type: "json", bytes: byte_size(encoded)}}
          {:error, reason} -> {:error, {:invalid_json_body, reason}}
        end

      true ->
        {:ok, nil, %{type: "none", bytes: 0}}
    end
  end

  defp capped_integer(nil, default, max), do: {:ok, min(default, max)}

  defp capped_integer(value, _default, max) when is_integer(value) and value >= 1 do
    if value <= max, do: {:ok, value}, else: {:error, {:value_above_cap, value, max}}
  end

  defp capped_integer(value, _default, _max), do: {:error, {:invalid_integer, value}}

  defp error_spec(params, settings, profile, reason) do
    uri = URI.parse("http://invalid.local/")

    %__MODULE__{
      method: "GET",
      url: "http://invalid.local/",
      uri: uri,
      profile: profile,
      host: "invalid.local",
      path: "/",
      query: nil,
      headers: [],
      body: nil,
      body_summary: %{type: "none", bytes: 0},
      timeout_ms: settings.default_timeout_ms,
      max_response_bytes: settings.max_response_bytes,
      allow_redirects?: settings.allow_redirects?,
      max_redirects: settings.max_redirects,
      retry_policy: settings.retry_policy,
      redact_request_headers: settings.redact_request_headers,
      redact_response_headers: settings.redact_response_headers,
      source_text: string_value(params, :source_text),
      denial_reason: reason,
      enabled?: settings.enabled?,
      profile_enabled?: false,
      allowed_hosts: settings.allowed_hosts,
      blocked_hosts: settings.blocked_hosts,
      allowed_paths: settings.allowed_paths,
      allowed_methods: settings.allowed_methods
    }
  end

  defp path(%URI{path: path}) when is_binary(path) and path != "", do: path
  defp path(_uri), do: "/"

  defp normalized_names(values), do: Enum.map(values || [], &String.downcase(to_string(&1)))

  defp preview(value) when is_binary(value) do
    if byte_size(value) > 200, do: binary_part(value, 0, 200), else: value
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp string_value(map, key) do
    case value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end
end
