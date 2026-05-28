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

  @doc "Return Jido model alias strings mirrored by config/config.exs."
  def jido_model_aliases, do: map_section!("jido_model_aliases")

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
    provider_type
    |> models_for_provider()
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

  defp models_for_provider(provider_type) do
    @catalog
    |> get_in(["models", provider_type])
    |> case do
      models when is_list(models) -> models
      _other -> []
    end
  end

  defp model_matches?(entry, model), do: model in model_ids(entry)

  defp model_ids(entry) do
    id = Map.get(entry, "id")
    aliases = Map.get(entry, "aliases", [])

    [id | aliases]
    |> Enum.filter(&is_binary/1)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
