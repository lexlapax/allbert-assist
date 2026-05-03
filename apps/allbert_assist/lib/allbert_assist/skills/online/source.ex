defmodule AllbertAssist.Skills.Online.Source do
  @moduledoc """
  Settings-backed online skill source profile.

  Source profiles bound online skill discovery/import to known endpoints and
  size limits. They do not grant execution or trust to imported skills.
  """

  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Skills.Online.RegistryClient

  defstruct id: nil,
            enabled?: false,
            online_import_enabled?: false,
            base_url: nil,
            api_url: nil,
            max_listing_results: 25,
            max_download_bytes: 1_048_576,
            cache_ttl_seconds: 3600,
            req_options: []

  @type t :: %__MODULE__{}

  @spec load(String.t() | nil, map()) :: {:ok, t()} | {:error, term()}
  def load(source_id \\ "skills_sh", context \\ %{}) do
    source_id = normalize_source(source_id || "skills_sh")

    with {:ok, settings, _user_settings} <- Store.resolved_settings(),
         online_settings <- get_in(settings, ["skills", "online_import"]) || %{},
         source_settings <- get_in(online_settings, ["sources", source_id]) || %{},
         online_enabled? <- Map.get(online_settings, "enabled", false),
         allowed_sources <- Map.get(online_settings, "allowed_sources", []),
         :ok <- source_allowed(source_id, allowed_sources),
         source_enabled? <- Map.get(source_settings, "enabled", false),
         base_url <- Map.get(source_settings, "base_url"),
         api_url <- Map.get(source_settings, "api_url"),
         max_listing_results <- Map.get(online_settings, "max_listing_results", 25),
         max_download_bytes <- Map.get(online_settings, "max_download_bytes", 1_048_576),
         cache_ttl_seconds <- Map.get(source_settings, "cache_ttl_seconds", 3600) do
      {:ok,
       %__MODULE__{
         id: source_id,
         enabled?: online_enabled? and source_enabled?,
         online_import_enabled?: online_enabled?,
         base_url: trim_url(base_url),
         api_url: trim_url(api_url),
         max_listing_results: max_listing_results,
         max_download_bytes: max_download_bytes,
         cache_ttl_seconds: cache_ttl_seconds,
         req_options: req_options(context)
       }}
    end
  end

  @spec validate_enabled(t()) :: :ok | {:error, term()}
  def validate_enabled(%__MODULE__{online_import_enabled?: false}),
    do: {:error, :online_skill_import_disabled}

  def validate_enabled(%__MODULE__{enabled?: false, id: source}),
    do: {:error, {:online_skill_source_disabled, source}}

  def validate_enabled(%__MODULE__{base_url: nil}), do: {:error, :online_skill_base_url_missing}
  def validate_enabled(%__MODULE__{api_url: nil}), do: {:error, :online_skill_api_url_missing}
  def validate_enabled(%__MODULE__{}), do: :ok

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = source) do
    %{
      id: source.id,
      enabled?: source.enabled?,
      online_import_enabled?: source.online_import_enabled?,
      base_url: source.base_url,
      api_url: source.api_url,
      max_listing_results: source.max_listing_results,
      max_download_bytes: source.max_download_bytes,
      cache_ttl_seconds: source.cache_ttl_seconds
    }
  end

  defp source_allowed(source_id, allowed_sources) do
    allowed = Enum.map(allowed_sources || [], &normalize_source/1)

    if source_id in allowed do
      :ok
    else
      {:error, {:online_skill_source_not_allowed, source_id}}
    end
  end

  defp normalize_source(source) do
    source
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
  end

  defp trim_url(nil), do: nil

  defp trim_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp req_options(context) do
    Map.get(context, :req_options) ||
      :allbert_assist
      |> Application.get_env(RegistryClient, [])
      |> Keyword.get(:req_options, [])
  end
end
