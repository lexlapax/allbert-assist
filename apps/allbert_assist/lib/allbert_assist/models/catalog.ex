defmodule AllbertAssist.Models.Catalog do
  @moduledoc """
  Read-only, no-hosted-egress model catalog assembled from shipped metadata,
  localhost runtime inventory, configured profiles, and bounded LLMDB metadata.
  """

  alias AllbertAssist.FirstModel.Ollama
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelCapabilities
  alias AllbertAssist.Settings.ModelRoles
  alias AllbertAssist.Settings.Store

  @catalog_path "model_catalog.json"
  @spec list(keyword()) ::
          {:ok, %{version: pos_integer(), entries: [map()], diagnostics: [map()]}}
  def list(opts \\ []) do
    {shipped, diagnostics} = shipped_catalog(opts)
    pulled = Keyword.get_lazy(opts, :pulled_models, &Ollama.model_tags/0)
    profiles = Keyword.get_lazy(opts, :profiles, &configured_profiles/0)
    roles = Keyword.get_lazy(opts, :roles, &configured_roles/0)

    direct_answer_target =
      Keyword.get_lazy(opts, :direct_answer_target, fn -> direct_answer_target(profiles) end)

    entries =
      shipped
      |> annotate_pulled(pulled)
      |> merge_runtime(pulled)
      |> merge_profiles(profiles, pulled)
      |> annotate_direct_answer_repair(direct_answer_target)
      |> annotate_assigned_roles(roles)
      |> Enum.sort_by(&sort_key/1)

    {:ok, %{version: 1, entries: entries, roles: roles, diagnostics: diagnostics}}
  end

  defp shipped_catalog(opts) do
    path =
      Keyword.get(
        opts,
        :catalog_path,
        Application.app_dir(:allbert_assist, "priv/#{@catalog_path}")
      )

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"local" => local, "hosted" => hosted}} <- Jason.decode(bytes) do
      {Enum.map(local ++ hosted, &normalize_shipped/1), []}
    else
      _error -> {[], [%{code: :curated_catalog_unavailable, source: :curated}]}
    end
  end

  defp normalize_shipped(row) do
    values =
      for key <-
            ~w(id provider model label size_bytes floor_gb capabilities purposes license thinking),
          into: %{},
          do: {String.to_existing_atom(key), Map.get(row, key)}

    Map.merge(values, %{
      source: if(values.provider == "ollama", do: :curated, else: :hosted_metadata),
      pulled?: false,
      pullable?: values.provider == "ollama",
      configured?: false,
      selectable?: false,
      status: :available
    })
  end

  defp annotate_pulled(rows, pulled) do
    Enum.map(rows, fn row ->
      if row.provider == "ollama" and row.model in pulled,
        do: %{row | pulled?: true, pullable?: false, status: :ready},
        else: row
    end)
  end

  defp merge_runtime(rows, pulled) do
    known = MapSet.new(Enum.map(rows, & &1.model))

    rows ++
      for model <- pulled, not MapSet.member?(known, model) do
        %{
          id: "ollama:#{model}",
          provider: "ollama",
          model: model,
          label: model,
          capabilities: ["text"],
          purposes: ["configured"],
          source: :runtime,
          pulled?: true,
          pullable?: false,
          configured?: false,
          selectable?: false,
          status: :ready,
          floor_gb: nil,
          size_bytes: nil,
          license: "unknown",
          thinking: false
        }
      end
  end

  defp merge_profiles(rows, profiles, pulled) do
    rows ++
      Enum.map(profiles, fn profile ->
        host_managed? = Map.get(profile, :provider_target) == :host_ollama
        pulled? = host_managed? and profile.model in pulled

        %{
          id: "profile:#{profile.name}",
          profile: profile.name,
          provider: to_string(profile.provider),
          model: profile.model,
          label: profile.name,
          capabilities: Enum.map(profile.capabilities, &to_string/1),
          purposes: ["configured"],
          source: :configured,
          pulled?: pulled?,
          pullable?: host_managed? and not pulled?,
          configured?: true,
          selectable?: text_generation_profile?(profile),
          status: configured_status(host_managed?, pulled?),
          floor_gb: nil,
          size_bytes: nil,
          license: "provider/model terms",
          thinking: false
        }
      end)
  end

  defp configured_status(true, true), do: :ready
  defp configured_status(true, false), do: :not_pulled
  defp configured_status(false, _pulled?), do: :configured

  defp configured_profiles do
    case Settings.list_model_profiles() do
      {:ok, profiles} -> Enum.map(profiles, &annotate_provider_target/1)
      _error -> []
    end
  end

  defp configured_roles do
    case Store.resolved_settings() do
      {:ok, settings, _user_settings} -> ModelRoles.catalog(settings)
      _error -> ModelRoles.catalog(%{})
    end
  end

  defp annotate_provider_target(%{provider: provider} = profile) do
    target =
      with "local_ollama" <- to_string(provider),
           "local_endpoint" <- Map.get(profile, :provider_endpoint_kind),
           {:ok, provider_profile} <- Settings.resolve_provider_profile(to_string(provider)),
           true <- Ollama.provider_targets_host_runtime?(provider_profile.base_url) do
        :host_ollama
      else
        _configured_or_unavailable -> :configured_endpoint
      end

    Map.put(profile, :provider_target, target)
  end

  defp text_generation_profile?(profile) do
    ModelCapabilities.runtime_text_generation?(profile)
  end

  defp direct_answer_target(profiles) do
    with {:ok, task_profiles} <- Settings.get("model_preferences.tasks.direct_answer"),
         profile_name when is_binary(profile_name) <-
           direct_answer_profile_name(task_profiles),
         %{} = profile <- Enum.find(profiles, &(to_string(&1.name) == profile_name)) do
      profile
    else
      _unavailable -> nil
    end
  end

  defp direct_answer_profile_name([profile | _rest]) when is_binary(profile), do: profile

  defp direct_answer_profile_name(_empty_or_missing) do
    case Settings.get("model_preferences.primary") do
      {:ok, profile} when is_binary(profile) -> profile
      _unavailable -> nil
    end
  end

  defp annotate_direct_answer_repair(entries, target) do
    target_model = if is_map(target), do: Map.get(target, :model)
    host_target? = is_map(target) and Map.get(target, :provider_target) == :host_ollama

    Enum.map(entries, fn entry ->
      repair? =
        host_target? and entry.source == :curated and entry.pullable? and
          entry.model == target_model

      Map.put(entry, :direct_answer_repair?, repair?)
    end)
  end

  defp annotate_assigned_roles(entries, roles) do
    assigned =
      roles
      |> Enum.filter(&(is_binary(&1.profile) and &1.status == :assigned))
      |> Enum.group_by(& &1.profile, & &1.role)

    Enum.map(entries, fn entry ->
      Map.put(entry, :assigned_roles, Map.get(assigned, Map.get(entry, :profile), []))
    end)
  end

  defp sort_key(row), do: {if(row.source == :curated, do: 0, else: 1), row.id}
end
