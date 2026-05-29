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

  @doc "Return the shipped provider catalog."
  def catalog, do: @catalog

  @doc "Return Settings Central provider defaults from the shipped catalog."
  def providers, do: map_section!("providers")

  @doc "Return Settings Central model-profile defaults from the shipped catalog."
  def model_profiles, do: map_section!("model_profiles")

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
