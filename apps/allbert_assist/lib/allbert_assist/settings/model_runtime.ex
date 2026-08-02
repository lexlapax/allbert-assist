defmodule AllbertAssist.Settings.ModelRuntime do
  @moduledoc """
  Converts resolved Settings Central model profiles into ReqLLM call inputs.

  This is a plain helper module, not a stateful process. Settings Central and
  Secrets remain the source of operator-owned provider configuration.
  """

  alias AllbertAssist.Settings.Vault

  @openai_min_max_tokens 16
  @endpoint_digest_domain "allbert:model-runtime-effective-endpoint:v1\0"

  @type endpoint_class :: :local | :hosted
  @type effective_transport :: %{
          required(:endpoint_class) => endpoint_class(),
          required(:endpoint_sha256) => String.t(),
          required(:redacted_host) => String.t()
        }
  @type endpoint_error ::
          :invalid_effective_model_endpoint | :non_loopback_local_model_endpoint

  @spec model_spec(map()) :: {:ok, map()} | {:error, term()}
  def model_spec(%{provider_type: provider_type, model: model}) when is_binary(model) do
    with {:ok, provider} <- req_llm_provider(provider_type) do
      {:ok, %{provider: provider, id: model}}
    end
  end

  def model_spec(%{provider_type: provider_type, model: model}) when is_atom(model) do
    model_spec(%{provider_type: provider_type, model: Atom.to_string(model)})
  end

  def model_spec(profile), do: {:error, {:invalid_model_profile, profile}}

  @spec model_string(map()) :: {:ok, String.t()} | {:error, term()}
  def model_string(%{provider_type: provider_type, model: model}) when is_binary(model) do
    if provider_prefixed?(model) do
      {:ok, model}
    else
      case req_llm_provider(provider_type) do
        {:ok, provider} -> {:ok, "#{provider}:#{model}"}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def model_string(%{name: name}) when is_binary(name), do: {:ok, name}
  def model_string(%{model: model}) when is_binary(model), do: {:ok, model}
  def model_string(profile), do: {:error, {:invalid_model_profile, profile}}

  @spec max_tokens(map(), pos_integer()) :: pos_integer()
  def max_tokens(profile, fallback)
      when is_map(profile) and is_integer(fallback) and fallback > 0 do
    profile
    |> Map.get(:max_tokens, fallback)
    |> normalize_max_tokens(fallback)
    |> maybe_raise_openai_minimum(profile)
  end

  def max_tokens(_profile, fallback) when is_integer(fallback) and fallback > 0, do: fallback

  @spec request_opts(map()) :: keyword()
  def request_opts(profile) when is_map(profile) do
    case effective_base_url(profile) do
      {:ok, base_url} ->
        []
        |> maybe_put_base_url(base_url)
        |> maybe_put_api_key(profile)
        |> maybe_put_openai_compatible_api_key(profile)

      {:error, reason}
      when reason in [:invalid_effective_model_endpoint, :non_loopback_local_model_endpoint] ->
        raise ArgumentError, "invalid effective model endpoint"
    end
  end

  def request_opts(_profile), do: []

  @doc """
  Return the secret-free identity and egress class of the endpoint a request
  will actually use.

  When exact request options are supplied, their `:base_url` wins. Otherwise
  this applies the same environment/profile precedence as `request_opts/1`.
  Raw URLs, userinfo, query values, and credentials never cross this boundary.
  """
  @spec effective_transport(map(), keyword() | nil) ::
          {:ok, effective_transport()} | {:error, endpoint_error()}
  def effective_transport(profile, request_opts \\ nil)

  def effective_transport(profile, request_opts)
      when is_map(profile) and (is_list(request_opts) or is_nil(request_opts)) do
    with {:ok, base_url} <- request_base_url(profile, request_opts) do
      endpoint_identity(profile, base_url)
    end
  end

  def effective_transport(_profile, _request_opts),
    do: {:error, :invalid_effective_model_endpoint}

  @doc "Return the exact validated environment/profile base URL used by `request_opts/1`."
  @spec effective_base_url(map()) ::
          {:ok, String.t() | nil} | {:error, endpoint_error()}
  def effective_base_url(profile) when is_map(profile) do
    with {:ok, base_url} <- profile |> base_url() |> valid_base_url(),
         :ok <- validate_endpoint_class(profile, base_url) do
      {:ok, base_url}
    end
  end

  def effective_base_url(_profile), do: {:error, :invalid_effective_model_endpoint}

  @spec req_llm_provider(String.t() | nil) :: {:ok, atom()} | {:error, term()}
  def req_llm_provider("openai"), do: {:ok, :openai}
  def req_llm_provider("openai_compatible"), do: {:ok, :openai}
  def req_llm_provider("local"), do: {:ok, :openai}
  def req_llm_provider("anthropic"), do: {:ok, :anthropic}
  def req_llm_provider("openrouter"), do: {:ok, :openrouter}
  def req_llm_provider("google"), do: {:ok, :google}
  def req_llm_provider(provider), do: {:error, {:unsupported_model_provider, provider}}

  @spec provider_string(String.t() | nil) :: String.t() | nil
  def provider_string(provider_type) do
    case req_llm_provider(provider_type) do
      {:ok, provider} -> Atom.to_string(provider)
      {:error, _reason} -> nil
    end
  end

  defp provider_prefixed?(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _model] ->
        provider in ~w[anthropic openai openai_codex openrouter google mistral]

      _other ->
        false
    end
  end

  defp maybe_put_base_url(opts, base_url) when is_binary(base_url) and base_url != "",
    do: Keyword.put(opts, :base_url, base_url)

  defp maybe_put_base_url(opts, _base_url), do: opts

  defp base_url(%{provider: "local_ollama"} = profile) do
    env_base_url("OLLAMA_BASE_URL") || Map.get(profile, :provider_base_url)
  end

  defp base_url(%{provider_type: "openai_compatible"} = profile) do
    env_base_url("OLLAMA_BASE_URL") || Map.get(profile, :provider_base_url)
  end

  defp base_url(profile), do: Map.get(profile, :provider_base_url)

  defp env_base_url(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _missing ->
        nil
    end
  end

  defp endpoint_identity(profile, nil) do
    provider = Map.get(profile, :provider) || Map.get(profile, "provider") || "unknown"

    provider_type =
      Map.get(profile, :provider_type) || Map.get(profile, "provider_type") || "unknown"

    endpoint_class = configured_endpoint_class(profile)

    {:ok,
     %{
       endpoint_class: endpoint_class,
       endpoint_sha256: endpoint_sha256(["default", provider, provider_type]),
       redacted_host: "provider-default"
     }}
  end

  defp endpoint_identity(_profile, base_url) when is_binary(base_url) do
    uri = URI.parse(String.trim(base_url))

    if valid_uri?(uri) do
      host = String.downcase(uri.host)

      {:ok,
       %{
         endpoint_class: if(loopback_host?(host), do: :local, else: :hosted),
         endpoint_sha256:
           endpoint_sha256([
             String.downcase(uri.scheme),
             host,
             Integer.to_string(uri.port || default_port(uri.scheme)),
             uri.path || ""
           ]),
         redacted_host: host
       }}
    else
      {:error, :invalid_effective_model_endpoint}
    end
  end

  defp configured_endpoint_class(profile) do
    case Map.get(profile, :provider_endpoint_kind) || Map.get(profile, "provider_endpoint_kind") ||
           Map.get(profile, :endpoint_kind) || Map.get(profile, "endpoint_kind") do
      value when value in [:local_endpoint, "local_endpoint"] -> :local
      _other -> :hosted
    end
  end

  defp validate_endpoint_class(profile, base_url) when is_binary(base_url) do
    host = base_url |> URI.parse() |> Map.fetch!(:host) |> String.downcase()

    if configured_endpoint_class(profile) == :local and not loopback_host?(host),
      do: {:error, :non_loopback_local_model_endpoint},
      else: :ok
  end

  defp validate_endpoint_class(_profile, _provider_default), do: :ok

  defp request_base_url(profile, nil), do: effective_base_url(profile)

  defp request_base_url(profile, request_opts) when is_list(request_opts) do
    with {:ok, base_url} <- request_opts |> Keyword.get(:base_url) |> valid_base_url(),
         :ok <- validate_endpoint_class(profile, base_url) do
      {:ok, base_url}
    end
  end

  defp valid_base_url(nil), do: {:ok, nil}

  defp valid_base_url(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, nil}
      valid_uri?(URI.parse(value)) -> {:ok, value}
      true -> {:error, :invalid_effective_model_endpoint}
    end
  end

  defp valid_base_url(_value), do: {:error, :invalid_effective_model_endpoint}

  defp valid_uri?(uri) do
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp loopback_host?(host)
       when host in ["localhost", "localhost.localdomain", "host.docker.internal", "::1"],
       do: true

  defp loopback_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> false
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp endpoint_sha256(parts) do
    parts
    |> Enum.intersperse(<<0>>)
    |> then(&:crypto.hash(:sha256, [@endpoint_digest_domain, &1]))
    |> Base.encode16(case: :lower)
  end

  defp maybe_put_api_key(opts, profile) do
    case Map.get(profile, :provider_api_key_ref) || Map.get(profile, :api_key_ref) do
      ref when is_binary(ref) ->
        # M8.3: resolve through the tier vault so a key stored in the OS Keychain is read
        # back at runtime (falls back to the tier-2 store for pre-migration keys).
        put_secret_api_key(opts, Vault.get(ref, %{trusted?: true}))

      _missing ->
        opts
    end
  end

  defp put_secret_api_key(opts, {:ok, key}) when is_binary(key) do
    key = String.trim(key)
    if key == "", do: opts, else: Keyword.put(opts, :api_key, key)
  end

  defp put_secret_api_key(opts, _secret_result), do: opts

  defp maybe_put_openai_compatible_api_key(opts, %{provider_type: "openai_compatible"}) do
    if Keyword.has_key?(opts, :api_key) do
      opts
    else
      Keyword.put(opts, :api_key, "ollama")
    end
  end

  defp maybe_put_openai_compatible_api_key(opts, _profile), do: opts

  defp normalize_max_tokens(value, _fallback) when is_integer(value) and value > 0, do: value

  defp normalize_max_tokens(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> fallback
    end
  end

  defp normalize_max_tokens(_value, fallback), do: fallback

  defp maybe_raise_openai_minimum(value, %{provider_type: "openai"}),
    do: max(value, @openai_min_max_tokens)

  defp maybe_raise_openai_minimum(value, _profile), do: value
end
