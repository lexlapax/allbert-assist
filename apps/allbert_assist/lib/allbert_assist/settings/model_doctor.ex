defmodule AllbertAssist.Settings.ModelDoctor do
  @moduledoc """
  Bounded provider/model profile doctor for first-run setup.

  The doctor accepts only Settings Central model profile names. It derives the
  probe target from the configured provider profile and returns the redacted
  ADR 0047 summary shape.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  @max_timeout_ms 5_000
  @default_timeout_ms 3_000
  @metadata_hosts ~w(metadata.google.internal metadata 169.254.169.254)
  @local_hostnames ~w(localhost localhost.localdomain host.docker.internal)

  @type summary :: %{
          endpoint_kind: :credentialed_remote | :local_endpoint,
          credential_ok: boolean() | nil,
          endpoint_ok: boolean(),
          model_available: boolean() | :unknown,
          context_window: pos_integer() | nil,
          deprecation_warning: String.t() | nil,
          last_seen_rate_limit_hint: String.t() | nil,
          redacted_host: String.t(),
          diagnostics: [map()]
        }

  @spec diagnose(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def diagnose(profile_name, context \\ %{})

  def diagnose(profile_name, context) when is_binary(profile_name) do
    with {:ok, model_profile} <- Settings.resolve_model_profile(profile_name),
         {:ok, provider_profile} <- Settings.resolve_provider_profile(model_profile.provider) do
      endpoint_kind = endpoint_kind(provider_profile.endpoint_kind)

      result =
        case endpoint_kind do
          :local_endpoint ->
            diagnose_local(model_profile, provider_profile, context)

          :credentialed_remote ->
            diagnose_remote(model_profile, provider_profile, context)
        end

      {:ok,
       result
       |> Map.put(:profile, profile_name)
       |> Map.put(:model, model_profile.model)
       |> Map.put(:provider, provider_profile.name)
       |> Map.put(:provider_type, provider_profile.type)}
    end
  end

  def diagnose(_profile_name, _context), do: {:error, :invalid_model_profile}

  defp diagnose_local(model_profile, provider_profile, context) do
    with {:ok, url} <- local_tags_url(provider_profile),
         {:ok, uri} <- validate_probe_url(url, :local_endpoint),
         {:ok, response} <- request(:get, uri, [], timeout_ms(model_profile), context) do
      local_response_summary(uri, model_profile.model, response)
    else
      {:error, {:host_denied, reason, host}} ->
        base_summary(:local_endpoint, host, [
          diagnostic(
            :provider_host_denied,
            "Local endpoint host is not allowed: #{inspect(reason)}."
          )
        ])

      {:error, {:invalid_url, reason}} ->
        base_summary(:local_endpoint, "unknown", [
          diagnostic(
            :invalid_provider_base_url,
            "Provider base URL is invalid: #{inspect(reason)}."
          )
        ])

      {:error, {:transport_error, reason, url}} ->
        host = url |> URI.parse() |> redacted_host()

        base_summary(:local_endpoint, host, [
          diagnostic(
            :endpoint_unreachable,
            "Local endpoint did not respond: #{safe_reason(reason)}."
          )
        ])
    end
  end

  defp diagnose_remote(model_profile, provider_profile, context) do
    with {:ok, credential} <- provider_credential(provider_profile),
         {:ok, url} <- remote_models_url(provider_profile),
         {:ok, uri} <- validate_probe_url(url, :credentialed_remote),
         {:ok, response} <-
           request(
             :get,
             uri,
             credential_headers(provider_profile.type, credential),
             timeout_ms(model_profile),
             context
           ) do
      remote_response_summary(uri, model_profile.model, response)
    else
      {:error, {:credential_missing, host}} ->
        base_summary(:credentialed_remote, host, [
          diagnostic(:credential_missing, "Provider credential is not configured.")
        ])

      {:error, {:credential_unavailable, reason, host}} ->
        base_summary(:credentialed_remote, host, [
          diagnostic(
            :credential_unavailable,
            "Provider credential could not be read: #{inspect(reason)}."
          )
        ])

      {:error, {:host_denied, reason, host}} ->
        base_summary(:credentialed_remote, host, [
          diagnostic(
            :provider_host_denied,
            "Credentialed-remote provider host is not allowed: #{inspect(reason)}."
          )
        ])

      {:error, {:invalid_url, reason}} ->
        base_summary(:credentialed_remote, "unknown", [
          diagnostic(
            :invalid_provider_base_url,
            "Provider base URL is invalid: #{inspect(reason)}."
          )
        ])

      {:error, {:transport_error, reason, url}} ->
        host = url |> URI.parse() |> redacted_host()

        base_summary(:credentialed_remote, host, [
          diagnostic(
            :endpoint_unreachable,
            "Provider endpoint did not respond: #{safe_reason(reason)}."
          )
        ])
    end
  end

  defp local_response_summary(uri, model, %{status: status} = response) when status in 200..299 do
    host = redacted_host(uri)
    rate_limit_hint = rate_limit_hint(response)

    response.body
    |> decode_json()
    |> local_catalog_summary(host, model, rate_limit_hint)
  end

  defp local_response_summary(uri, _model, response) do
    host = redacted_host(uri)

    summary(:local_endpoint, host,
      credential_ok: nil,
      endpoint_ok: false,
      model_available: :unknown,
      last_seen_rate_limit_hint: rate_limit_hint(response),
      diagnostics: [
        diagnostic(:endpoint_http_error, "Local endpoint returned HTTP #{response.status}.")
      ]
    )
  end

  defp local_catalog_summary({:ok, body}, host, model, rate_limit_hint) do
    body
    |> find_model(model)
    |> local_model_summary(host, model, rate_limit_hint)
  end

  defp local_catalog_summary({:error, _reason}, host, _model, rate_limit_hint) do
    summary(:local_endpoint, host,
      credential_ok: nil,
      endpoint_ok: true,
      model_available: :unknown,
      last_seen_rate_limit_hint: rate_limit_hint,
      diagnostics: [
        diagnostic(
          :invalid_catalog_response,
          "Local endpoint returned an unreadable model list."
        )
      ]
    )
  end

  defp local_model_summary(nil, host, model, rate_limit_hint) do
    summary(:local_endpoint, host,
      credential_ok: nil,
      endpoint_ok: true,
      model_available: false,
      last_seen_rate_limit_hint: rate_limit_hint,
      diagnostics: [
        diagnostic(
          :local_model_missing,
          "Local model #{model} is not installed. Run `ollama pull #{model}` and retry."
        )
      ]
    )
  end

  defp local_model_summary(entry, host, _model, rate_limit_hint) do
    summary(:local_endpoint, host,
      credential_ok: nil,
      endpoint_ok: true,
      model_available: true,
      context_window: context_window(entry),
      deprecation_warning: deprecation_warning(entry),
      last_seen_rate_limit_hint: rate_limit_hint,
      diagnostics: []
    )
  end

  defp remote_response_summary(uri, model, %{status: status} = response)
       when status in 200..299 do
    host = redacted_host(uri)
    rate_limit_hint = rate_limit_hint(response)

    response.body
    |> decode_json()
    |> remote_catalog_summary(host, model, rate_limit_hint)
  end

  defp remote_response_summary(uri, _model, response) do
    host = redacted_host(uri)
    rate_limit_hint = rate_limit_hint(response)

    cond do
      response.status in [401, 403] ->
        summary(:credentialed_remote, host,
          credential_ok: false,
          endpoint_ok: true,
          model_available: :unknown,
          last_seen_rate_limit_hint: rate_limit_hint,
          diagnostics: [
            diagnostic(:credential_rejected, "Provider rejected the configured credential.")
          ]
        )

      response.status == 429 ->
        summary(:credentialed_remote, host,
          credential_ok: true,
          endpoint_ok: true,
          model_available: :unknown,
          last_seen_rate_limit_hint: rate_limit_hint,
          diagnostics: [diagnostic(:rate_limited, "Provider rate-limited the model-list probe.")]
        )

      true ->
        summary(:credentialed_remote, host,
          credential_ok: response.status < 500,
          endpoint_ok: false,
          model_available: :unknown,
          last_seen_rate_limit_hint: rate_limit_hint,
          diagnostics: [
            diagnostic(
              :endpoint_http_error,
              "Provider endpoint returned HTTP #{response.status}."
            )
          ]
        )
    end
  end

  defp remote_catalog_summary({:ok, body}, host, model, rate_limit_hint) do
    body
    |> find_model(model)
    |> remote_model_summary(host, model, rate_limit_hint)
  end

  defp remote_catalog_summary({:error, _reason}, host, _model, rate_limit_hint) do
    summary(:credentialed_remote, host,
      credential_ok: true,
      endpoint_ok: true,
      model_available: :unknown,
      last_seen_rate_limit_hint: rate_limit_hint,
      diagnostics: [
        diagnostic(
          :invalid_catalog_response,
          "Provider returned an unreadable model list."
        )
      ]
    )
  end

  defp remote_model_summary(nil, host, model, rate_limit_hint) do
    summary(:credentialed_remote, host,
      credential_ok: true,
      endpoint_ok: true,
      model_available: false,
      last_seen_rate_limit_hint: rate_limit_hint,
      diagnostics: [
        diagnostic(
          :model_not_listed,
          "Configured model #{model} was not listed by provider."
        )
      ]
    )
  end

  defp remote_model_summary(entry, host, _model, rate_limit_hint) do
    summary(:credentialed_remote, host,
      credential_ok: true,
      endpoint_ok: true,
      model_available: true,
      context_window: context_window(entry),
      deprecation_warning: deprecation_warning(entry),
      last_seen_rate_limit_hint: rate_limit_hint,
      diagnostics: []
    )
  end

  defp provider_credential(%{api_key_ref: nil} = provider),
    do: {:error, {:credential_missing, provider_host(provider)}}

  defp provider_credential(%{api_key_ref: ref} = provider) do
    host = provider_host(provider)

    case Secrets.get_secret(ref, %{trusted?: true}) do
      {:ok, value} when is_binary(value) ->
        credential = String.trim(value)

        if byte_size(credential) >= 8 do
          {:ok, credential}
        else
          {:error, {:credential_unavailable, :invalid_credential_format, host}}
        end

      {:ok, _value} ->
        {:error, {:credential_unavailable, :invalid_credential_format, host}}

      {:error, {:secret_not_found, _ref}} ->
        {:error, {:credential_missing, host}}

      {:error, reason} ->
        {:error, {:credential_unavailable, reason, host}}
    end
  end

  defp provider_host(%{type: type, base_url: base_url}) do
    case remote_base_url(type, base_url) do
      {:ok, url} -> redacted_host(url)
      {:error, _reason} -> redacted_host(base_url)
    end
  end

  defp credential_headers("anthropic", credential) do
    [
      {"x-api-key", credential},
      {"anthropic-version", "2023-06-01"},
      {"accept", "application/json"}
    ]
  end

  defp credential_headers(_provider_type, credential) do
    [
      {"authorization", "Bearer #{credential}"},
      {"accept", "application/json"}
    ]
  end

  defp request(method, uri, headers, timeout_ms, context) do
    url = URI.to_string(uri)

    [
      method: method,
      url: url,
      headers: headers,
      receive_timeout: timeout_ms,
      retry: false,
      redirect: false,
      max_redirects: 0,
      compressed: false,
      decode_body: false
    ]
    |> maybe_put(:plug, req_test_plug(context))
    |> Req.request()
    |> case do
      {:ok, response} -> {:ok, response}
      {:error, %Req.TransportError{} = error} -> {:error, {:transport_error, error.reason, url}}
      {:error, reason} -> {:error, {:transport_error, reason, url}}
    end
  end

  defp local_tags_url(%{base_url: nil}), do: {:ok, "http://localhost:11434/api/tags"}

  defp local_tags_url(%{base_url: base_url}) when is_binary(base_url) do
    uri = URI.parse(base_url)
    root_path = local_root_path(uri.path || "")

    {:ok,
     uri
     |> Map.put(:path, join_paths(root_path, "/api/tags"))
     |> Map.put(:query, nil)
     |> Map.put(:fragment, nil)
     |> URI.to_string()}
  end

  defp remote_models_url(%{type: type, base_url: base_url}) do
    with {:ok, base_url} <- remote_base_url(type, base_url) do
      uri = URI.parse(base_url)

      {:ok,
       uri
       |> Map.put(:path, join_paths(uri.path || "", "/models"))
       |> Map.put(:query, nil)
       |> Map.put(:fragment, nil)
       |> URI.to_string()}
    else
      {:error, reason} -> {:error, {:invalid_url, reason}}
    end
  end

  defp remote_base_url("openai", nil), do: {:ok, "https://api.openai.com/v1"}
  defp remote_base_url("anthropic", nil), do: {:ok, "https://api.anthropic.com/v1"}
  defp remote_base_url("openrouter", nil), do: {:ok, "https://openrouter.ai/api/v1"}

  defp remote_base_url(_type, base_url) when is_binary(base_url) and base_url != "",
    do: {:ok, base_url}

  defp remote_base_url(type, _base_url), do: {:error, {:missing_base_url, type}}

  defp validate_probe_url(url, endpoint_kind) do
    uri = URI.parse(url)

    with :ok <- validate_basic_uri(uri),
         :ok <- validate_host_policy(uri.host, endpoint_kind) do
      {:ok, uri}
    else
      {:error, {:host_denied, reason}} -> {:error, {:host_denied, reason, uri.host || "unknown"}}
      {:error, reason} -> {:error, {:invalid_url, reason}}
    end
  end

  defp validate_basic_uri(%URI{scheme: scheme}) when scheme not in ["http", "https"],
    do: {:error, {:unsupported_scheme, scheme}}

  defp validate_basic_uri(%URI{host: host}) when not is_binary(host) or host == "",
    do: {:error, :missing_host}

  defp validate_basic_uri(%URI{userinfo: userinfo}) when is_binary(userinfo) and userinfo != "",
    do: {:error, :url_credentials_not_allowed}

  defp validate_basic_uri(_uri), do: :ok

  defp validate_host_policy(host, _kind) when host in @metadata_hosts,
    do: {:error, {:host_denied, :metadata_host}}

  defp validate_host_policy(host, :credentialed_remote) do
    if local_host?(host), do: {:error, {:host_denied, :private_host}}, else: :ok
  end

  defp validate_host_policy(host, :local_endpoint) do
    if local_host?(host), do: :ok, else: {:error, {:host_denied, :non_local_host}}
  end

  defp local_host?(host) when is_binary(host) do
    host = String.downcase(host)

    cond do
      host in @local_hostnames -> true
      String.ends_with?(host, ".local") -> true
      ip = parse_ip(host) -> private_ip?(ip)
      true -> false
    end
  end

  defp local_host?(_host), do: false

  defp parse_ip(host) do
    host
    |> to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, second, _, _}) when second >= 16 and second <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({100, second, _, _}) when second >= 64 and second <= 127, do: true
  defp private_ip?({first, _, _, _}) when first >= 224, do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ip?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFE00) == 0xFC00,
    do: true

  defp private_ip?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFFC0) == 0xFE80,
    do: true

  defp private_ip?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFF00) == 0xFF00,
    do: true

  defp private_ip?(_ip), do: false

  defp decode_json(body) when is_binary(body), do: Jason.decode(body)
  defp decode_json(%{} = body), do: {:ok, body}
  defp decode_json(_body), do: {:error, :invalid_body}

  defp find_model(body, model) when is_map(body) do
    body
    |> model_entries()
    |> Enum.find(&model_entry_matches?(&1, model))
  end

  defp find_model(_body, _model), do: nil

  defp model_entries(%{"data" => entries}) when is_list(entries), do: entries
  defp model_entries(%{"models" => entries}) when is_list(entries), do: entries
  defp model_entries(_body), do: []

  defp model_entry_matches?(%{} = entry, model) do
    model_id(entry) == model
  end

  defp model_entry_matches?(_entry, _model), do: false

  defp model_id(entry) do
    Map.get(entry, "id") || Map.get(entry, "model") || Map.get(entry, "name")
  end

  defp context_window(entry) do
    ["context_window", "context_length", "context", "max_context_length"]
    |> Enum.find_value(fn key ->
      case Map.get(entry, key) do
        value when is_integer(value) and value > 0 -> value
        value when is_binary(value) -> parse_positive_integer(value)
        _other -> nil
      end
    end)
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp deprecation_warning(entry) do
    cond do
      Map.get(entry, "deprecated") == true ->
        "Model is marked deprecated."

      expiration = Map.get(entry, "expiration_date") ->
        "Model expiration date: #{expiration}."

      warning = Map.get(entry, "deprecation_warning") ->
        to_string(warning)

      warning = Map.get(entry, "deprecation") ->
        to_string(warning)

      true ->
        nil
    end
  end

  defp rate_limit_hint(response) do
    headers = normalize_headers(response.headers)

    ["retry-after", "x-ratelimit-remaining-requests", "x-ratelimit-reset-requests"]
    |> Enum.find_value(fn header ->
      case Map.get(headers, header) do
        nil -> nil
        value -> "#{header}=#{String.slice(value, 0, 80)}"
      end
    end)
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} ->
      value = if is_list(value), do: Enum.join(value, ","), else: to_string(value)
      {String.downcase(to_string(key)), value}
    end)
  end

  defp base_summary(endpoint_kind, host, diagnostics) do
    summary(endpoint_kind, host,
      credential_ok: if(endpoint_kind == :local_endpoint, do: nil, else: false),
      endpoint_ok: false,
      model_available: :unknown,
      diagnostics: diagnostics
    )
  end

  defp summary(endpoint_kind, host, opts) do
    %{
      endpoint_kind: endpoint_kind,
      credential_ok: Keyword.get(opts, :credential_ok),
      endpoint_ok: Keyword.fetch!(opts, :endpoint_ok),
      model_available: Keyword.fetch!(opts, :model_available),
      context_window: Keyword.get(opts, :context_window),
      deprecation_warning: Keyword.get(opts, :deprecation_warning),
      last_seen_rate_limit_hint: Keyword.get(opts, :last_seen_rate_limit_hint),
      redacted_host: host || "unknown",
      diagnostics: Keyword.get(opts, :diagnostics, [])
    }
  end

  defp diagnostic(code, message), do: %{code: code, message: message}

  defp endpoint_kind("local_endpoint"), do: :local_endpoint
  defp endpoint_kind(:local_endpoint), do: :local_endpoint
  defp endpoint_kind(_kind), do: :credentialed_remote

  defp timeout_ms(profile) do
    value = Map.get(profile, :timeout_ms) || @default_timeout_ms

    cond do
      not is_integer(value) -> @default_timeout_ms
      value < 1 -> @default_timeout_ms
      true -> min(value, @max_timeout_ms)
    end
  end

  defp local_root_path(path) when path in ["", "/"], do: ""
  defp local_root_path(path), do: String.trim_trailing(path, "/v1")

  defp join_paths("", suffix), do: suffix
  defp join_paths("/", suffix), do: suffix

  defp join_paths(prefix, suffix) do
    String.trim_trailing(prefix, "/") <> "/" <> String.trim_leading(suffix, "/")
  end

  defp redacted_host(%URI{host: host}) when is_binary(host) and host != "", do: host

  defp redacted_host(url) when is_binary(url) do
    url
    |> URI.parse()
    |> redacted_host()
  end

  defp redacted_host(_value), do: "unknown"

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason), do: reason |> inspect() |> String.slice(0, 80)

  defp req_test_plug(context) do
    context
    |> field(:req_options, [])
    |> Keyword.get(:plug)
  end

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)

  defp field(map, key, fallback) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key), fallback)

  defp field(_value, _key, fallback), do: fallback
end
