defmodule AllbertAssist.Voice.ProviderHTTP do
  @moduledoc """
  Voice-provider HTTP substrate.

  This module owns the v0.48 voice HTTP posture: local endpoints are loopback
  only, remote endpoints are HTTPS-only, credentials only come from Settings
  Secrets, redirects/retries are disabled, and diagnostics never contain raw
  credentials, audio, provider bodies, or file paths.
  """

  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Voice.LocalRuntime.Auth

  @metadata_hosts ~w[metadata.google.internal metadata 169.254.169.254]
  @local_hostnames ~w[localhost localhost.localdomain]
  @default_openai_base_url "https://api.openai.com/v1"
  @default_gemini_base_url "https://generativelanguage.googleapis.com/v1beta"
  @default_timeout_ms 30_000

  @type endpoint :: %{
          required(:url) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          required(:redacted_host) => String.t()
        }

  @spec endpoint(map(), String.t(), keyword()) :: {:ok, endpoint()} | {:error, term()}
  def endpoint(profile, path, opts \\ []) when is_map(profile) and is_binary(path) do
    with {:ok, base_url} <- base_url(profile),
         uri = URI.parse(base_url),
         :ok <- validate_base_uri(uri, endpoint_kind(profile)),
         {:ok, headers} <- credential_headers(profile),
         {:ok, url} <- build_url(uri, path) do
      {:ok,
       %{
         url: url,
         headers: headers ++ Keyword.get(opts, :headers, []),
         redacted_host: redacted_host(uri)
       }}
    end
  end

  @spec request(atom(), endpoint(), keyword(), map(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def request(method, endpoint, request_opts, profile, opts \\ []) when is_map(endpoint) do
    request_headers = Keyword.get(request_opts, :headers, [])
    request_opts = Keyword.delete(request_opts, :headers)

    [
      method: method,
      url: endpoint.url,
      headers: endpoint.headers ++ request_headers,
      receive_timeout: timeout_ms(profile),
      retry: false,
      redirect: false,
      max_redirects: 0
    ]
    |> Keyword.merge(request_opts)
    |> maybe_put(:plug, req_test_plug(opts))
    |> Req.request()
    |> case do
      {:ok, %{status: status} = response} when status >= 200 and status < 300 ->
        {:ok, response}

      {:ok, %{status: status}} ->
        {:error, {:voice_http_error, status}}

      {:error, %Req.TransportError{} = error} ->
        {:error, {:voice_transport_error, error.reason}}

      {:error, reason} ->
        {:error, {:voice_transport_error, reason}}
    end
  end

  @spec json_body(Req.Response.t()) :: {:ok, map()} | {:error, term()}
  def json_body(%{body: body}) when is_map(body), do: {:ok, body}

  def json_body(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :invalid_voice_json_response}
      {:error, _reason} -> {:error, :invalid_voice_json_response}
    end
  end

  def json_body(_response), do: {:error, :invalid_voice_json_response}

  @spec audio_body(Req.Response.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def audio_body(%{body: body}, max_bytes) when is_binary(body) and is_integer(max_bytes) do
    if byte_size(body) <= max_bytes do
      {:ok, body}
    else
      {:error, {:audio_output_too_large, byte_size(body), max_bytes}}
    end
  end

  def audio_body(_response, _max_bytes), do: {:error, :invalid_voice_audio_response}

  @spec content_type(Req.Response.t()) :: String.t() | nil
  def content_type(%{headers: headers}) when is_map(headers) do
    headers
    |> Map.get("content-type")
    |> case do
      [value | _rest] -> value
      value when is_binary(value) -> value
      _missing -> nil
    end
  end

  def content_type(_response), do: nil

  @spec redacted_host(String.t() | URI.t() | nil) :: String.t()
  def redacted_host(%URI{host: host}) when is_binary(host), do: host
  def redacted_host(value) when is_binary(value), do: value |> URI.parse() |> redacted_host()
  def redacted_host(_value), do: "unknown"

  @spec mime_type_for_path(String.t(), String.t() | nil) :: String.t()
  def mime_type_for_path(path, fallback \\ nil) do
    case path |> Path.extname() |> String.trim_leading(".") |> String.downcase() do
      "wav" -> "audio/wav"
      "mp3" -> "audio/mpeg"
      "m4a" -> "audio/mp4"
      "ogg" -> "audio/ogg"
      "webm" -> "audio/webm"
      "flac" -> "audio/flac"
      _other -> fallback || "application/octet-stream"
    end
  end

  @spec output_mime_type(String.t()) :: String.t()
  def output_mime_type("wav"), do: "audio/wav"
  def output_mime_type("mp3"), do: "audio/mpeg"
  def output_mime_type("m4a"), do: "audio/mp4"
  def output_mime_type("aac"), do: "audio/aac"
  def output_mime_type("opus"), do: "audio/opus"
  def output_mime_type("ogg"), do: "audio/ogg"
  def output_mime_type("flac"), do: "audio/flac"
  def output_mime_type(format), do: "audio/#{format}"

  @spec max_audio_bytes(map(), pos_integer()) :: pos_integer()
  def max_audio_bytes(%{media: media}, default) when is_map(media) do
    case Map.get(media, "max_audio_bytes") || Map.get(media, :max_audio_bytes) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  def max_audio_bytes(_profile, default), do: default

  defp base_url(%{provider_endpoint_kind: "local_endpoint", provider_base_url: base_url})
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp base_url(%{provider_endpoint_kind: "local_endpoint"}),
    do: {:error, :missing_local_voice_base_url}

  defp base_url(%{media: %{"deployment_mode" => "local_endpoint"}, provider_base_url: base_url})
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp base_url(%{media: %{deployment_mode: "local_endpoint"}, provider_base_url: base_url})
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp base_url(%{media: %{"deployment_mode" => "local_endpoint"}}),
    do: {:error, :missing_local_voice_base_url}

  defp base_url(%{media: %{deployment_mode: "local_endpoint"}}),
    do: {:error, :missing_local_voice_base_url}

  defp base_url(%{provider_type: "openai", provider_base_url: base_url})
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp base_url(%{provider_type: "openai"}), do: {:ok, @default_openai_base_url}

  defp base_url(%{provider_type: "google", provider_base_url: base_url})
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp base_url(%{provider_type: "google"}), do: {:ok, @default_gemini_base_url}

  defp base_url(%{provider_base_url: base_url}) when is_binary(base_url) and base_url != "",
    do: {:ok, base_url}

  defp base_url(%{provider_type: type}), do: {:error, {:missing_voice_base_url, type}}
  defp base_url(_profile), do: {:error, :missing_voice_base_url}

  defp validate_base_uri(%URI{} = uri, :local_endpoint) do
    with :ok <- validate_basic_uri(uri),
         :ok <- validate_no_query_or_fragment(uri),
         :ok <- validate_local_uri(uri) do
      :ok
    end
  end

  defp validate_base_uri(%URI{} = uri, :credentialed_remote) do
    with :ok <- validate_basic_uri(uri),
         :ok <- validate_no_query_or_fragment(uri),
         :ok <- validate_remote_uri(uri) do
      :ok
    end
  end

  defp validate_basic_uri(%URI{scheme: scheme}) when scheme not in ["http", "https"],
    do: {:error, {:unsupported_voice_endpoint_scheme, scheme}}

  defp validate_basic_uri(%URI{host: host}) when not is_binary(host) or host == "",
    do: {:error, :missing_voice_endpoint_host}

  defp validate_basic_uri(%URI{userinfo: userinfo}) when is_binary(userinfo) and userinfo != "",
    do: {:error, :voice_endpoint_credentials_in_url_denied}

  defp validate_basic_uri(_uri), do: :ok

  defp validate_no_query_or_fragment(%URI{query: query}) when is_binary(query) and query != "",
    do: {:error, :voice_endpoint_query_denied}

  defp validate_no_query_or_fragment(%URI{fragment: fragment})
       when is_binary(fragment) and fragment != "",
       do: {:error, :voice_endpoint_fragment_denied}

  defp validate_no_query_or_fragment(_uri), do: :ok

  defp validate_local_uri(%URI{host: host}) do
    if loopback_host?(host), do: :ok, else: {:error, {:voice_local_host_denied, host}}
  end

  defp validate_remote_uri(%URI{scheme: scheme}) when scheme != "https",
    do: {:error, {:voice_remote_https_required, scheme}}

  defp validate_remote_uri(%URI{host: host}) do
    cond do
      metadata_host?(host) -> {:error, {:voice_remote_host_denied, :metadata_host}}
      private_host?(host) -> {:error, {:voice_remote_host_denied, :private_host}}
      true -> :ok
    end
  end

  defp credential_headers(profile) do
    case endpoint_kind(profile) do
      :local_endpoint ->
        {:ok,
         [{"accept", "application/json"}] ++ Auth.header_for_base_url(local_base_url(profile))}

      :credentialed_remote ->
        credentialed_headers(profile)
    end
  end

  defp credentialed_headers(profile) when is_map(profile) do
    case {Map.get(profile, :provider_type), Map.get(profile, :provider_api_key_ref)} do
      {provider_type, ref} when is_binary(provider_type) and provider_type != "" ->
        with {:ok, credential} <- provider_credential(ref, profile) do
          {:ok, provider_headers(provider_type, credential)}
        end

      {provider_type, _ref} ->
        {:error, {:voice_credential_missing, provider_type}}
    end
  end

  defp provider_credential(ref, profile) when is_binary(ref) and ref != "" do
    case Secrets.get_secret(ref, %{trusted?: true}) do
      {:ok, credential} when is_binary(credential) ->
        credential = String.trim(credential)
        if credential == "", do: credential_missing(profile), else: {:ok, credential}

      {:error, {:secret_not_found, _ref}} ->
        credential_missing(profile)

      {:error, reason} ->
        {:error, {:voice_credential_unavailable, provider_type(profile), reason}}
    end
  end

  defp provider_credential(_ref, profile), do: credential_missing(profile)

  defp credential_missing(profile),
    do: {:error, {:voice_credential_missing, provider_type(profile)}}

  defp provider_headers("google", credential) do
    [
      {"x-goog-api-key", credential},
      {"accept", "application/json"}
    ]
  end

  defp provider_headers(_provider_type, credential) do
    [
      {"authorization", "Bearer #{credential}"},
      {"accept", "application/json"}
    ]
  end

  defp local_base_url(profile) when is_map(profile) do
    Map.get(profile, :provider_base_url) ||
      Map.get(profile, "provider_base_url") ||
      get_in(profile, [:media, "base_url"]) ||
      get_in(profile, ["media", "base_url"])
  end

  defp build_url(%URI{} = uri, path) do
    path = join_paths(uri.path || "", path)

    {:ok,
     uri
     |> Map.put(:path, path)
     |> Map.put(:query, nil)
     |> Map.put(:fragment, nil)
     |> URI.to_string()}
  end

  defp join_paths(base_path, path) do
    joined =
      [String.trim(base_path || "", "/"), String.trim(path, "/")]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("/")

    "/" <> joined
  end

  defp endpoint_kind(%{provider_endpoint_kind: "local_endpoint"}), do: :local_endpoint
  defp endpoint_kind(%{provider_endpoint_kind: "credentialed_remote"}), do: :credentialed_remote
  defp endpoint_kind(%{media: %{"deployment_mode" => "local_endpoint"}}), do: :local_endpoint
  defp endpoint_kind(%{media: %{deployment_mode: "local_endpoint"}}), do: :local_endpoint
  defp endpoint_kind(_profile), do: :credentialed_remote

  defp timeout_ms(%{timeout_ms: timeout_ms}) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms

  defp timeout_ms(_profile), do: @default_timeout_ms

  defp req_test_plug(opts) do
    opts
    |> Keyword.get(:req_options, [])
    |> Keyword.get(:plug, Keyword.get(opts, :plug))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp provider_type(profile) when is_map(profile), do: Map.get(profile, :provider_type)

  defp metadata_host?(host) when is_binary(host), do: String.downcase(host) in @metadata_hosts
  defp metadata_host?(_host), do: false

  defp loopback_host?(host) when is_binary(host) do
    host = String.downcase(host)

    cond do
      host in @local_hostnames -> true
      ip = parse_ip(host) -> loopback_ip?(ip)
      true -> false
    end
  end

  defp loopback_host?(_host), do: false

  defp private_host?(host) when is_binary(host) do
    host = String.downcase(host)

    cond do
      host in @local_hostnames -> true
      String.ends_with?(host, ".local") -> true
      ip = parse_ip(host) -> private_ip?(ip)
      true -> false
    end
  end

  defp private_host?(_host), do: false

  defp parse_ip(host) do
    host
    |> to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> normalize_ip(ip)
      {:error, _reason} -> nil
    end
  end

  defp normalize_ip({0, 0, 0, 0, 0, 65_535, high, low})
       when is_integer(high) and high >= 0 and high <= 65_535 and is_integer(low) and low >= 0 and
              low <= 65_535 do
    {div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)}
  end

  defp normalize_ip(ip), do: ip

  defp loopback_ip?({127, _, _, _}), do: true
  defp loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_ip?(_ip), do: false

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
end
