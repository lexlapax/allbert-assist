defmodule AllbertAssist.FirstRun.UsableModel do
  @moduledoc """
  Minimal deterministic first-run model selector.

  This module grants no authority and performs no hosted probe. Local health
  comes from Model Doctor; hosted readiness means configured credential
  presence only. M4's catalog reuses these ordering rules.
  """

  alias AllbertAssist.FirstModel.Ollama
  alias AllbertAssist.Settings.ModelDoctor
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store

  @hosted_provider_order ~w(openai anthropic google openrouter)

  @type selection :: %{
          profile: String.t(),
          provider: String.t(),
          provider_class: :local | :hosted,
          verification: :doctor_healthy | :configured_unverified
        }

  @spec select(keyword()) :: {:ok, selection()} | {:error, :no_usable_model}
  def select(opts \\ []) do
    with {:ok, settings, _user_settings} <- resolved_settings(opts) do
      case select_local(settings, opts) do
        {:ok, selection} -> {:ok, selection}
        {:error, :no_usable_model} -> select_hosted(settings)
      end
    else
      _error -> {:error, :no_usable_model}
    end
  end

  @spec select_local(map(), keyword()) :: {:ok, selection()} | {:error, :no_usable_model}
  def select_local(settings, opts \\ []) when is_map(settings) do
    doctor = Keyword.get(opts, :doctor, &ModelDoctor.diagnose/1)
    tags = Keyword.get_lazy(opts, :tags, &Ollama.model_tags/0)
    curated = Keyword.get_lazy(opts, :curated_model, &Ollama.curated_model/0)

    local_profiles(settings)
    |> Enum.find_value(fn {name, attrs} ->
      case doctor.(name) do
        {:ok, %{endpoint_ok: true, model_available: true}} -> local_selection(name, attrs)
        _other -> nil
      end
    end)
    |> case do
      nil -> select_curated_local(settings, tags, curated)
      selection -> {:ok, selection}
    end
  end

  @spec select_hosted(map()) :: {:ok, selection()} | {:error, :no_usable_model}
  def select_hosted(settings) when is_map(settings) do
    settings
    |> ordered_profile_names()
    |> Enum.map(&{&1, get_in(settings, ["model_profiles", &1])})
    |> Enum.filter(fn {_name, attrs} -> hosted_profile?(attrs, settings) end)
    |> Enum.sort_by(fn {name, attrs} -> hosted_sort_key(name, attrs, settings) end)
    |> List.first()
    |> case do
      {name, attrs} ->
        {:ok,
         %{
           profile: name,
           provider: attrs["provider"],
           provider_class: :hosted,
           verification: :configured_unverified
         }}

      nil ->
        {:error, :no_usable_model}
    end
  end

  defp select_curated_local(settings, tags, curated) do
    local_profiles(settings)
    |> Enum.find(fn {_name, attrs} -> attrs["model"] == curated and curated in tags end)
    |> case do
      {name, attrs} -> {:ok, local_selection(name, attrs)}
      nil -> {:error, :no_usable_model}
    end
  end

  defp local_profiles(settings) do
    settings
    |> ordered_profile_names()
    |> Enum.map(&{&1, get_in(settings, ["model_profiles", &1])})
    |> Enum.filter(fn {_name, attrs} -> local_profile?(attrs, settings) end)
  end

  defp ordered_profile_names(settings) do
    primary = get_in(settings, ["model_preferences", "primary"])
    direct = get_in(settings, ["model_preferences", "tasks", "direct_answer"]) || []
    all = settings |> Map.get("model_profiles", %{}) |> Map.keys() |> Enum.sort()

    [primary | direct ++ all]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp local_profile?(attrs, settings) when is_map(attrs) do
    case get_in(settings, ["providers", attrs["provider"]]) do
      %{"enabled" => true, "endpoint_kind" => "local_endpoint"} -> text_profile?(attrs)
      _other -> false
    end
  end

  defp local_profile?(_attrs, _settings), do: false

  defp hosted_profile?(attrs, settings) when is_map(attrs) do
    case get_in(settings, ["providers", attrs["provider"]]) do
      %{"enabled" => true, "endpoint_kind" => "credentialed_remote"} = provider ->
        provider_configured?(provider) and text_profile?(attrs)

      _other ->
        false
    end
  end

  defp hosted_profile?(_attrs, _settings), do: false

  defp provider_configured?(%{"credential_status" => :configured}), do: true

  defp provider_configured?(%{"api_key_ref" => ref}) when is_binary(ref),
    do: Secrets.status(ref) == :configured

  defp provider_configured?(_provider), do: false

  defp text_profile?(%{"capabilities" => capabilities}) when is_list(capabilities),
    do: "text_generation" in capabilities

  # Existing pre-capability profiles are text-generation profiles unless they
  # explicitly declare another capability. This keeps v1.2 additive.
  defp text_profile?(attrs), do: is_binary(attrs["model"]) and attrs["model"] != ""

  defp hosted_sort_key(name, attrs, settings) do
    primary = get_in(settings, ["model_preferences", "primary"])
    direct = get_in(settings, ["model_preferences", "tasks", "direct_answer"]) || []
    provider = get_in(settings, ["providers", attrs["provider"]]) || %{}
    provider_type = provider["type"] || attrs["provider"]

    preference_rank =
      cond do
        name == primary -> {0, 0}
        name in direct -> {1, Enum.find_index(direct, &(&1 == name)) || 0}
        true -> {2, 0}
      end

    provider_rank = Enum.find_index(@hosted_provider_order, &(&1 == provider_type)) || 999
    {preference_rank, provider_rank, attrs["provider"], name}
  end

  defp local_selection(name, attrs) do
    %{
      profile: name,
      provider: attrs["provider"],
      provider_class: :local,
      verification: :doctor_healthy
    }
  end

  defp resolved_settings(opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, settings} -> {:ok, settings, %{}}
      :error -> Store.resolved_settings()
    end
  end
end
