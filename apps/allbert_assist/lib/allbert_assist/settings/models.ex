defmodule AllbertAssist.Settings.Models do
  @moduledoc """
  Capability-aware model preference resolver.

  This is a plain Settings helper. It selects a configured model profile from
  operator-owned preferences and grants no runtime authority by itself.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelCapabilities
  alias AllbertAssist.Settings.ModelRoles
  alias AllbertAssist.Settings.ProviderCatalog
  alias AllbertAssist.Settings.ProviderEligibility
  alias AllbertAssist.Settings.Store

  @task_capabilities %{
    "coding" => "text_generation",
    "direct_answer" => "text_generation",
    "fanout_manager" => "text_generation",
    "fanout_synthesis" => "text_generation"
  }
  @closed_task_chains ~w[direct_answer fanout_manager fanout_synthesis]

  @type resolution :: %{
          optional(:requested_reference) => String.t(),
          optional(:requested_role) => String.t(),
          optional(:resolved_profile) => String.t(),
          request: String.t(),
          request_kind: :task | :capability,
          capability: String.t(),
          profile: map(),
          profile_name: String.t(),
          source: :preference | :primary,
          diagnostics: [map()]
        }

  @doc "Resolve a model profile for a task or capability."
  @spec unquote(:for)(atom() | String.t() | {:task | :capability, atom() | String.t()}, map()) ::
          {:ok, resolution()} | {:error, term()}
  def unquote(:for)(request, context \\ %{}) do
    with {:ok, settings, user_settings} <- Store.resolved_settings(),
         {:ok, request_kind, request_name, capability} <- normalize_request(request, settings) do
      resolve(request_kind, request_name, capability, settings, user_settings, context)
    end
  end

  @doc """
  Return every configured capable profile for a task or capability in ranked order.

  This is used by provider-call actions that need to retry a bounded provider
  failure against the next operator-ranked profile. It applies the same
  capability, enabled-provider, and primary-fallback checks as `for/2`.
  """
  @spec candidates_for(
          atom() | String.t() | {:task | :capability, atom() | String.t()},
          map()
        ) ::
          {:ok, [resolution()]} | {:error, term()}
  def candidates_for(request, context \\ %{}) do
    with {:ok, settings, user_settings} <- Store.resolved_settings(),
         {:ok, request_kind, request_name, capability} <- normalize_request(request, settings) do
      resolve_candidates(request_kind, request_name, capability, settings, user_settings, context)
    end
  end

  @doc "Return true when a resolved profile declares a capability."
  @spec capable?(map(), atom() | String.t()) :: boolean()
  def capable?(profile, capability) when is_map(profile) do
    ModelCapabilities.runtime_supports?(profile, capability)
  end

  def capable?(_profile, _capability), do: false

  @doc "Resolve one concrete profile name or closed `role:*` reference."
  @spec resolve_reference(String.t(), map()) :: {:ok, map()} | {:skip, map()}
  def resolve_reference(reference, settings) when is_binary(reference) and is_map(settings) do
    case ModelRoles.role_for_reference(reference) do
      {:ok, role} ->
        case ModelRoles.mapped_profile(settings, role) do
          nil ->
            {:skip, role_diagnostic(reference, role, nil, :unconfigured_role)}

          profile_name when is_binary(profile_name) ->
            if get_in(settings, ["model_profiles", profile_name]) do
              {:ok,
               %{
                 requested_reference: reference,
                 requested_role: role,
                 resolved_profile: profile_name
               }}
            else
              {:skip, role_diagnostic(reference, role, profile_name, :missing_profile)}
            end
        end

      :error ->
        {:ok,
         %{
           requested_reference: reference,
           requested_role: nil,
           resolved_profile: reference
         }}
    end
  end

  defp normalize_request({:task, task}, _settings) do
    task = normalize_name(task)
    {:ok, :task, task, Map.get(@task_capabilities, task, "text_generation")}
  end

  defp normalize_request({:capability, capability}, _settings) do
    normalize_capability(capability)
  end

  defp normalize_request(request, settings) do
    name = normalize_name(request)

    cond do
      task_preference?(settings, name) ->
        {:ok, :task, name, Map.get(@task_capabilities, name, "text_generation")}

      name in ProviderCatalog.known_capabilities() ->
        {:ok, :capability, name, name}

      true ->
        {:error, {:unknown_model_request, request}}
    end
  end

  defp normalize_capability(capability) do
    capability = normalize_name(capability)

    if capability in ProviderCatalog.known_capabilities() do
      {:ok, :capability, capability, capability}
    else
      {:error, {:unknown_capability, capability}}
    end
  end

  defp resolve(request_kind, request_name, capability, settings, user_settings, _context) do
    preference_profiles = preference_profiles(settings, request_kind, request_name)
    primary = Settings.Schema.get_dotted(settings, "model_preferences.primary")

    candidates =
      ranked_candidates(
        request_kind,
        request_name,
        preference_profiles,
        primary
      )

    expanded = expand_candidates(candidates, settings)

    case first_capable_profile(expanded, capability, settings, user_settings) do
      {:ok, profile, candidate, diagnostics} ->
        {:ok, resolution(request_name, request_kind, capability, profile, candidate, diagnostics)}

      {:error, diagnostics} ->
        {:error,
         {:no_capable_profile,
          %{
            request: request_name,
            request_kind: request_kind,
            capability: capability,
            candidates: Enum.map(candidates, &elem(&1, 0)),
            diagnostics: diagnostics
          }}}
    end
  end

  defp preference_profiles(settings, :task, task) do
    Settings.Schema.get_dotted(settings, "model_preferences.tasks.#{task}") || []
  end

  defp preference_profiles(settings, :capability, capability) do
    Settings.Schema.get_dotted(settings, "model_preferences.capabilities.#{capability}") || []
  end

  defp preference_candidates(profiles), do: Enum.map(profiles, &{&1, :preference})

  # Purpose-qualified text tasks own complete selection/failover sets. Appending
  # the global primary could silently route advisory content through a model
  # that was never qualified for that purpose. Only DirectAnswer retains ADR
  # 0051's empty-chain compatibility fallback; fanout_synthesis is non-empty.
  defp ranked_candidates(:task, task, preferences, _primary)
       when task in @closed_task_chains and preferences != [] do
    preference_candidates(preferences)
  end

  defp ranked_candidates(:task, "direct_answer", [], primary) do
    primary_fallback([], primary)
  end

  defp ranked_candidates(:task, task, [], _primary)
       when task in ["fanout_manager", "fanout_synthesis"],
       do: []

  defp ranked_candidates(_kind, _name, preferences, primary) do
    preference_candidates(preferences) ++ primary_fallback(preferences, primary)
  end

  defp primary_fallback(candidates, primary) when is_binary(primary) and primary != "" do
    if primary in candidates, do: [], else: [{primary, :primary}]
  end

  defp primary_fallback(_candidates, _primary), do: []

  defp first_capable_profile(candidates, capability, settings, user_settings) do
    Enum.reduce_while(candidates, {:error, []}, fn
      {:skip, diagnostic}, {:error, diagnostics} ->
        {:cont, {:error, [diagnostic | diagnostics]}}

      {:candidate, candidate}, {:error, diagnostics} ->
        case validate_candidate(candidate, capability, settings, user_settings) do
          {:ok, profile} ->
            {:halt, {:ok, profile, candidate, Enum.reverse(diagnostics)}}

          {:skip, diagnostic} ->
            {:cont, {:error, [diagnostic | diagnostics]}}
        end
    end)
    |> case do
      {:error, diagnostics} -> {:error, Enum.reverse(diagnostics)}
      other -> other
    end
  end

  defp resolve_candidates(
         request_kind,
         request_name,
         capability,
         settings,
         user_settings,
         _context
       ) do
    preference_profiles = preference_profiles(settings, request_kind, request_name)
    primary = Settings.Schema.get_dotted(settings, "model_preferences.primary")

    candidates =
      ranked_candidates(
        request_kind,
        request_name,
        preference_profiles,
        primary
      )

    candidates
    |> expand_candidates(settings)
    |> Enum.reduce({[], []}, fn
      {:skip, diagnostic}, {resolutions, diagnostics} ->
        {resolutions, [diagnostic | diagnostics]}

      {:candidate, candidate}, {resolutions, diagnostics} ->
        case validate_candidate(candidate, capability, settings, user_settings) do
          {:ok, profile} ->
            resolved =
              resolution(
                request_name,
                request_kind,
                capability,
                profile,
                candidate,
                Enum.reverse(diagnostics)
              )

            {[resolved | resolutions], diagnostics}

          {:skip, diagnostic} ->
            {resolutions, [diagnostic | diagnostics]}
        end
    end)
    |> case do
      {[], diagnostics} ->
        {:error,
         {:no_capable_profile,
          %{
            request: request_name,
            request_kind: request_kind,
            capability: capability,
            candidates: Enum.map(candidates, &elem(&1, 0)),
            diagnostics: Enum.reverse(diagnostics)
          }}}

      {resolutions, _diagnostics} ->
        {:ok, Enum.reverse(resolutions)}
    end
  end

  defp validate_candidate(candidate, capability, settings, user_settings) do
    profile_name = candidate.resolved_profile

    with {:ok, attrs} <- fetch_profile_attrs(profile_name, settings),
         :ok <- validate_profile_capability(profile_name, attrs, capability),
         :ok <- validate_provider_enabled(profile_name, attrs, settings, user_settings),
         {:ok, profile} <- Settings.resolve_model_profile(profile_name) do
      {:ok, Map.put(profile, :provider_enabled, true)}
    else
      {:error, reason} -> {:skip, diagnostic(candidate, reason)}
    end
  end

  defp fetch_profile_attrs(profile_name, settings) do
    case get_in(settings, ["model_profiles", profile_name]) do
      attrs when is_map(attrs) -> {:ok, attrs}
      _missing -> {:error, :missing_profile}
    end
  end

  defp validate_profile_capability(profile_name, attrs, capability) do
    if ModelCapabilities.runtime_supports?(attrs, capability) do
      :ok
    else
      {:error, {:profile_missing_capability, profile_name, capability}}
    end
  end

  defp validate_provider_enabled(profile_name, attrs, settings, user_settings) do
    provider = Map.get(attrs, "provider")

    case get_in(settings, ["providers", provider]) do
      provider_attrs when is_map(provider_attrs) ->
        if ProviderEligibility.enabled?(provider, provider_attrs, user_settings) do
          :ok
        else
          {:error, {:provider_disabled, profile_name, provider}}
        end

      _missing ->
        {:error, {:provider_missing, profile_name, provider}}
    end
  end

  defp diagnostic(candidate, reason) do
    base = %{
      profile: candidate.resolved_profile,
      status: :skipped,
      reason: reason
    }

    if candidate.requested_role do
      Map.merge(base, %{
        requested_reference: candidate.requested_reference,
        requested_role: candidate.requested_role,
        resolved_profile: candidate.resolved_profile
      })
    else
      base
    end
  end

  defp role_diagnostic(reference, role, profile, reason) do
    %{
      profile: profile,
      status: :skipped,
      reason: reason,
      requested_reference: reference,
      requested_role: role,
      resolved_profile: profile
    }
  end

  defp expand_candidates(candidates, settings) do
    {_seen, expanded} =
      Enum.reduce(candidates, {MapSet.new(), []}, fn {reference, source}, {seen, rows} ->
        case resolve_reference(reference, settings) do
          {:skip, diagnostic} ->
            {seen, [{:skip, diagnostic} | rows]}

          {:ok, metadata} ->
            if MapSet.member?(seen, metadata.resolved_profile) do
              {seen, rows}
            else
              candidate = Map.put(metadata, :source, source)
              {MapSet.put(seen, metadata.resolved_profile), [{:candidate, candidate} | rows]}
            end
        end
      end)

    Enum.reverse(expanded)
  end

  defp resolution(request_name, request_kind, capability, profile, candidate, diagnostics) do
    base = %{
      request: request_name,
      request_kind: request_kind,
      capability: capability,
      profile: profile,
      profile_name: profile.name,
      source: candidate.source,
      diagnostics: diagnostics
    }

    if candidate.requested_role do
      Map.merge(base, %{
        requested_reference: candidate.requested_reference,
        requested_role: candidate.requested_role,
        resolved_profile: candidate.resolved_profile
      })
    else
      base
    end
  end

  defp task_preference?(settings, task) do
    settings
    |> Settings.Schema.get_dotted("model_preferences.tasks")
    |> case do
      tasks when is_map(tasks) -> Map.has_key?(tasks, task)
      _other -> false
    end
  end

  defp normalize_name(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_name(value) when is_binary(value), do: value
  defp normalize_name(value), do: to_string(value)
end
