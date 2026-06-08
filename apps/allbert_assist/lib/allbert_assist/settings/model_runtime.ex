defmodule AllbertAssist.Settings.ModelRuntime do
  @moduledoc """
  Converts resolved Settings Central model profiles into ReqLLM call inputs.

  This is a plain helper module, not a stateful process. Settings Central and
  Secrets remain the source of operator-owned provider configuration.
  """

  alias AllbertAssist.Settings.Secrets

  @openai_min_max_tokens 16

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
    []
    |> maybe_put_base_url(base_url(profile))
    |> maybe_put_api_key(profile)
    |> maybe_put_openai_compatible_api_key(profile)
  end

  def request_opts(_profile), do: []

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

  defp maybe_put_api_key(opts, profile) do
    case Map.get(profile, :provider_api_key_ref) || Map.get(profile, :api_key_ref) do
      ref when is_binary(ref) ->
        put_secret_api_key(opts, Secrets.get_secret(ref, %{trusted?: true}))

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
