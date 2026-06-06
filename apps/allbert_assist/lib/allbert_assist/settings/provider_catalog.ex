defmodule AllbertAssist.Settings.ProviderCatalog do
  @moduledoc """
  Shipped provider/model catalog for Settings Central defaults.

  This module is a static seed-data reader. It is not runtime authority:
  operator settings still override these defaults and provider doctors still
  probe live provider APIs before reporting availability.
  """

  @catalog_path Path.expand("../../../priv/provider_catalog/models.json", __DIR__)
  @external_resource @catalog_path
  @catalog @catalog_path |> File.read!() |> Jason.decode!()
  @known_capabilities ~w[
    text_generation
    speech_to_text
    text_to_speech
    vision_input
    image_generation
    video_input
    token_streaming
    embeddings
    tool_use
  ]
  @known_media_modalities ~w[text audio image video]
  @known_media_transport_modes ~w[
    request_file
    live_upload
    realtime_session
    local_endpoint
    bundled_local
  ]
  @known_media_deployment_modes ~w[
    fake
    local_endpoint
    bundled_local
    remote_credentialed
  ]
  @allowed_media_keys ~w[
    input_modalities
    output_modalities
    transport_modes
    deployment_mode
    audio_formats_supported
    audio_sample_rates_supported
    max_audio_bytes
    max_audio_duration_ms
  ]

  @doc "Return the shipped provider catalog."
  def catalog, do: @catalog

  @doc "Return the supported model/profile capability vocabulary."
  def known_capabilities, do: @known_capabilities

  @doc "Return the supported media modality vocabulary."
  def known_media_modalities, do: @known_media_modalities

  @doc "Return the supported provider transport mode vocabulary."
  def known_media_transport_modes, do: @known_media_transport_modes

  @doc "Return the supported deployment mode vocabulary."
  def known_media_deployment_modes, do: @known_media_deployment_modes

  @doc "Return Settings Central provider defaults from the shipped catalog."
  def providers, do: map_section!("providers")

  @doc "Return Settings Central model-profile defaults from the shipped catalog."
  def model_profiles, do: map_section!("model_profiles")

  @doc "Validate model-profile capabilities against the v0.48 vocabulary."
  def validate_capabilities(capabilities) when is_list(capabilities) do
    cond do
      capabilities == [] ->
        {:error, :empty_capabilities}

      Enum.all?(capabilities, &(&1 in @known_capabilities)) ->
        :ok

      true ->
        {:error, {:unknown_capability, Enum.reject(capabilities, &(&1 in @known_capabilities))}}
    end
  end

  def validate_capabilities(value), do: {:error, {:expected_capability_list, value}}

  @doc "Validate optional model-profile media metadata against the v0.48 vocabulary."
  def validate_media(media) when is_map(media) do
    Enum.reduce_while(media, :ok, fn {field, value}, :ok ->
      case validate_media_field(field, value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def validate_media(value), do: {:error, {:expected_media_map, value}}

  @doc "Validate the shipped provider catalog's profile capability metadata."
  def validate_catalog do
    providers = providers()

    model_profiles()
    |> Enum.reduce_while(:ok, fn {name, profile}, :ok ->
      case validate_catalog_profile(name, profile, providers) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Return Jido.AI model aliases generated from shipped model profiles."
  def jido_model_aliases do
    @catalog
    |> Map.fetch!("model_profiles")
    |> Enum.reduce(%{}, &put_jido_model_alias/2)
  end

  @doc "Install generated Jido.AI model aliases into runtime application env."
  @spec configure_jido_model_aliases!() :: :ok
  def configure_jido_model_aliases! do
    Application.put_env(:jido_ai, :model_aliases, jido_model_aliases())
  end

  @doc "Merge catalog-backed provider/model defaults into core settings defaults."
  @spec merge_defaults(map()) :: map()
  def merge_defaults(defaults) when is_map(defaults) do
    deep_merge(defaults, %{
      "providers" => providers(),
      "model_profiles" => model_profiles()
    })
  end

  @doc """
  Return known equivalent model ids for a provider/model pair.

  The first item is always the configured model. Catalog equivalents are only
  advisory aliases for doctor availability checks.
  """
  @spec equivalent_model_ids(String.t() | nil, String.t() | nil) :: [String.t()]
  def equivalent_model_ids(provider_type, model)
      when is_binary(provider_type) and is_binary(model) do
    @catalog
    |> Map.fetch!("model_profiles")
    |> Enum.map(fn {_name, profile} -> profile end)
    |> Enum.filter(&(profile_provider_type(&1) == provider_type))
    |> Enum.find(&model_matches?(&1, model))
    |> case do
      nil -> [model]
      entry -> [model | model_ids(entry)] |> Enum.uniq()
    end
  end

  def equivalent_model_ids(_provider_type, model) when is_binary(model), do: [model]
  def equivalent_model_ids(_provider_type, _model), do: []

  defp map_section!(key) do
    case Map.fetch!(@catalog, key) do
      section when is_map(section) -> section
    end
  end

  defp validate_catalog_profile(name, profile, providers) when is_map(profile) do
    with :ok <- validate_catalog_profile_provider(name, profile, providers),
         :ok <- validate_catalog_profile_model(name, profile),
         :ok <- validate_catalog_profile_capabilities(name, profile) do
      validate_catalog_profile_media(name, profile)
    end
  end

  defp validate_catalog_profile(name, profile, _providers),
    do: {:error, {:invalid_catalog_profile, name, {:expected_map, profile}}}

  defp validate_catalog_profile_provider(name, profile, providers) do
    provider = Map.get(profile, "provider")

    if is_binary(provider) and Map.has_key?(providers, provider) do
      :ok
    else
      {:error, {:invalid_catalog_profile, name, {:unknown_provider, provider}}}
    end
  end

  defp validate_catalog_profile_model(name, profile) do
    case Map.get(profile, "model") do
      model when is_binary(model) and model != "" ->
        :ok

      model ->
        {:error, {:invalid_catalog_profile, name, {:invalid_model, model}}}
    end
  end

  defp validate_catalog_profile_capabilities(name, profile) do
    case validate_capabilities(Map.get(profile, "capabilities")) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_catalog_profile, name, {:capabilities, reason}}}
    end
  end

  defp validate_catalog_profile_media(name, profile) do
    case validate_media(Map.get(profile, "media", %{})) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_catalog_profile, name, {:media, reason}}}
    end
  end

  defp validate_media_field(field, _value) when field not in @allowed_media_keys,
    do: {:error, {:unknown_media_field, field}}

  defp validate_media_field(field, value)
       when field in ["input_modalities", "output_modalities"] do
    validate_known_string_list(field, value, @known_media_modalities)
  end

  defp validate_media_field("transport_modes", value) do
    validate_known_string_list("transport_modes", value, @known_media_transport_modes)
  end

  defp validate_media_field("deployment_mode", value) do
    if value in @known_media_deployment_modes do
      :ok
    else
      {:error, {:invalid_deployment_mode, value}}
    end
  end

  defp validate_media_field("audio_formats_supported", value) when is_list(value) do
    if value != [] and Enum.all?(value, &valid_audio_format?/1) do
      :ok
    else
      {:error, {:invalid_audio_formats_supported, value}}
    end
  end

  defp validate_media_field("audio_formats_supported", value),
    do: {:error, {:expected_string_list, value}}

  defp validate_media_field("audio_sample_rates_supported", value) when is_list(value) do
    if value != [] and Enum.all?(value, &valid_audio_sample_rate?/1) do
      :ok
    else
      {:error, {:invalid_audio_sample_rates_supported, value}}
    end
  end

  defp validate_media_field("audio_sample_rates_supported", value),
    do: {:error, {:expected_positive_integer_list, value}}

  defp validate_media_field(field, value)
       when field in ["max_audio_bytes", "max_audio_duration_ms"] do
    if is_integer(value) and value > 0 and value <= 536_870_912 do
      :ok
    else
      {:error, {:invalid_positive_integer, field, value}}
    end
  end

  defp validate_known_string_list(field, value, allowed) when is_list(value) do
    if value != [] and Enum.all?(value, &(&1 in allowed)) do
      :ok
    else
      {:error, {:invalid_string_list, field, value}}
    end
  end

  defp validate_known_string_list(_field, value, _allowed),
    do: {:error, {:expected_string_list, value}}

  defp valid_audio_format?(value) when is_binary(value) do
    Regex.match?(~r/^[a-z0-9][a-z0-9+._-]{0,63}$/, value)
  end

  defp valid_audio_format?(_value), do: false

  defp valid_audio_sample_rate?(value) when is_integer(value),
    do: value > 0 and value <= 384_000

  defp valid_audio_sample_rate?(_value), do: false

  defp model_matches?(entry, model), do: model in model_ids(entry)

  defp model_ids(entry) do
    id = Map.get(entry, "model")
    aliases = Map.get(entry, "aliases", [])

    [id | aliases]
    |> Enum.filter(&is_binary/1)
  end

  defp put_jido_model_alias({name, profile}, aliases) do
    with provider when is_binary(provider) <- Map.get(profile, "provider"),
         provider_type when is_binary(provider_type) <- provider_type(provider),
         model when is_binary(model) <- Map.get(profile, "model"),
         jido_provider when is_binary(jido_provider) <- jido_provider(provider_type) do
      Map.put(aliases, String.to_atom(name), "#{jido_provider}:#{model}")
    else
      _missing -> aliases
    end
  end

  defp profile_provider_type(profile) do
    profile
    |> Map.get("provider")
    |> provider_type()
  end

  defp provider_type(provider) when is_binary(provider) do
    @catalog
    |> get_in(["providers", provider, "type"])
  end

  defp provider_type(_provider), do: nil

  defp jido_provider("anthropic"), do: "anthropic"
  defp jido_provider("openai"), do: "openai"
  defp jido_provider("openai_compatible"), do: "openai"
  defp jido_provider("openrouter"), do: "openrouter"
  defp jido_provider("google"), do: "google"
  defp jido_provider(_provider_type), do: nil

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
