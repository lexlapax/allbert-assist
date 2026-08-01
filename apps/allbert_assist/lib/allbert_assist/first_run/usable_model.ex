defmodule AllbertAssist.FirstRun.UsableModel do
  @moduledoc """
  Minimal deterministic first-run model selector.

  This module grants no authority and performs no hosted probe. Local health
  comes from Model Doctor; hosted readiness means configured credential
  presence only. M4's catalog reuses these ordering rules.
  """

  alias AllbertAssist.Settings.ModelCapabilities
  alias AllbertAssist.Settings.ModelDoctor
  alias AllbertAssist.Settings.ProviderEligibility
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
    with {:ok, settings, user_settings} <- resolved_settings(opts) do
      case select_local(settings, opts) do
        {:ok, selection} -> {:ok, selection}
        {:error, :no_usable_model} -> select_hosted(settings, user_settings)
      end
    else
      _error -> {:error, :no_usable_model}
    end
  end

  @spec select_local(map(), keyword()) :: {:ok, selection()} | {:error, :no_usable_model}
  def select_local(settings, opts \\ []) when is_map(settings) do
    doctor = Keyword.get(opts, :doctor, &ModelDoctor.diagnose/1)

    local_profiles(settings)
    |> Enum.find_value(fn {name, attrs} ->
      case doctor.(name) do
        {:ok, %{endpoint_ok: true, model_available: true}} -> local_selection(name, attrs)
        _other -> nil
      end
    end)
    |> case do
      nil -> {:error, :no_usable_model}
      selection -> {:ok, selection}
    end
  end

  @doc "Select a doctor-verified local profile from one purpose-owned task list."
  @spec select_local_for_task(String.t(), map(), keyword()) ::
          {:ok, selection()} | {:error, :no_usable_model}
  def select_local_for_task(task, settings, opts \\ [])
      when is_binary(task) and is_map(settings) do
    doctor = Keyword.get(opts, :doctor, &ModelDoctor.diagnose/1)

    profiles = task_local_profiles(task, settings)

    profiles
    |> Enum.find_value(fn {name, attrs} ->
      case doctor.(name) do
        {:ok, %{endpoint_ok: true, model_available: true}} -> local_selection(name, attrs)
        _other -> nil
      end
    end)
    |> case do
      nil -> {:error, :no_usable_model}
      selection -> {:ok, selection}
    end
  end

  @spec select_hosted(map(), map()) :: {:ok, selection()} | {:error, :no_usable_model}
  def select_hosted(settings, user_settings \\ %{})
      when is_map(settings) and is_map(user_settings) do
    profiles = hosted_text_profiles(settings)

    eligible_providers =
      profiles
      |> Enum.map(fn {_name, attrs} -> attrs["provider"] end)
      |> Enum.uniq()
      |> Map.new(fn provider_name ->
        {provider_name, hosted_provider_eligible?(provider_name, settings, user_settings)}
      end)

    profiles
    |> Enum.filter(fn {_name, attrs} -> Map.get(eligible_providers, attrs["provider"], false) end)
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

  @doc "Select an eligible hosted profile from one purpose-owned task list."
  @spec select_hosted_for_task(String.t(), map(), map()) ::
          {:ok, selection()} | {:error, :no_usable_model}
  def select_hosted_for_task(task, settings, user_settings \\ %{})
      when is_binary(task) and is_map(settings) and is_map(user_settings) do
    profiles = task_hosted_profiles(task, settings)

    profiles
    |> Enum.filter(fn {_name, attrs} ->
      hosted_provider_eligible?(attrs["provider"], settings, user_settings)
    end)
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

  defp task_local_profiles(task, settings) do
    task
    |> task_profile_names(settings)
    |> Enum.take(1)
    |> Enum.map(&{&1, get_in(settings, ["model_profiles", &1])})
    |> Enum.filter(fn {_name, attrs} -> local_profile?(attrs, settings) end)
  end

  defp task_hosted_profiles(task, settings) do
    task
    |> task_profile_names(settings)
    |> Enum.take(1)
    |> Enum.map(&{&1, get_in(settings, ["model_profiles", &1])})
    |> Enum.filter(fn {_name, attrs} ->
      is_map(attrs) and text_profile?(attrs) and hosted_endpoint?(attrs, settings)
    end)
  end

  defp task_profile_names(task, settings) do
    case get_in(settings, ["model_preferences", "tasks", task]) do
      profiles when is_list(profiles) and profiles != [] ->
        Enum.filter(profiles, &(is_binary(&1) and &1 != ""))

      _empty_or_missing ->
        case get_in(settings, ["model_preferences", "primary"]) do
          primary when is_binary(primary) and primary != "" -> [primary]
          _missing -> []
        end
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

  defp hosted_text_profiles(settings) do
    settings
    |> ordered_profile_names()
    |> Enum.map(&{&1, get_in(settings, ["model_profiles", &1])})
    |> Enum.filter(fn {_name, attrs} ->
      is_map(attrs) and text_profile?(attrs) and hosted_endpoint?(attrs, settings)
    end)
  end

  defp hosted_endpoint?(attrs, settings) do
    match?(
      %{"endpoint_kind" => "credentialed_remote"},
      get_in(settings, ["providers", attrs["provider"]])
    )
  end

  defp hosted_provider_eligible?(provider_name, settings, user_settings) do
    case get_in(settings, ["providers", provider_name]) do
      %{"endpoint_kind" => "credentialed_remote"} = provider ->
        ProviderEligibility.hosted_eligible?(provider_name, provider, user_settings)

      _other ->
        false
    end
  end

  defp text_profile?(attrs), do: ModelCapabilities.runtime_text_generation?(attrs)

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
    case {Keyword.fetch(opts, :settings), Keyword.fetch(opts, :user_settings)} do
      {{:ok, settings}, {:ok, user_settings}} -> {:ok, settings, user_settings}
      {{:ok, settings}, :error} -> {:ok, settings, %{}}
      _other -> Store.resolved_settings()
    end
  end
end
