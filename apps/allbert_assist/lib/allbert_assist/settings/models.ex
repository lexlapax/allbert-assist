defmodule AllbertAssist.Settings.Models do
  @moduledoc """
  Capability-aware model preference resolver.

  This is a plain Settings helper. It selects a configured model profile from
  operator-owned preferences and grants no runtime authority by itself.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ProviderCatalog
  alias AllbertAssist.Settings.Store

  @task_capabilities %{
    "coding" => "text_generation",
    "direct_answer" => "text_generation"
  }

  @type resolution :: %{
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
    with {:ok, settings, _user_settings} <- Store.resolved_settings(),
         {:ok, request_kind, request_name, capability} <- normalize_request(request, settings) do
      resolve(request_kind, request_name, capability, settings, context)
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
    with {:ok, settings, _user_settings} <- Store.resolved_settings(),
         {:ok, request_kind, request_name, capability} <- normalize_request(request, settings) do
      resolve_candidates(request_kind, request_name, capability, settings, context)
    end
  end

  @doc "Return true when a resolved profile declares a capability."
  @spec capable?(map(), atom() | String.t()) :: boolean()
  def capable?(profile, capability) when is_map(profile) do
    capability = normalize_name(capability)
    capability in Map.get(profile, :capabilities, [])
  end

  def capable?(_profile, _capability), do: false

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

  defp resolve(request_kind, request_name, capability, settings, _context) do
    preference_profiles = preference_profiles(settings, request_kind, request_name)
    primary = Settings.Schema.get_dotted(settings, "model_preferences.primary")

    candidates =
      preference_candidates(preference_profiles) ++ primary_fallback(preference_profiles, primary)

    case first_capable_profile(candidates, capability, settings) do
      {:ok, profile, source, diagnostics} ->
        {:ok,
         %{
           request: request_name,
           request_kind: request_kind,
           capability: capability,
           profile: profile,
           profile_name: profile.name,
           source: source,
           diagnostics: diagnostics
         }}

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

  defp primary_fallback(candidates, primary) when is_binary(primary) and primary != "" do
    if primary in candidates, do: [], else: [{primary, :primary}]
  end

  defp primary_fallback(_candidates, _primary), do: []

  defp first_capable_profile(candidates, capability, settings) do
    candidates
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.reduce_while({:error, []}, fn profile_name, {:error, diagnostics} ->
      case validate_candidate(profile_name, capability, settings) do
        {:ok, profile, source} ->
          {:halt, {:ok, profile, source, Enum.reverse(diagnostics)}}

        {:skip, diagnostic} ->
          {:cont, {:error, [diagnostic | diagnostics]}}
      end
    end)
    |> case do
      {:error, diagnostics} -> {:error, Enum.reverse(diagnostics)}
      other -> other
    end
  end

  defp resolve_candidates(request_kind, request_name, capability, settings, _context) do
    preference_profiles = preference_profiles(settings, request_kind, request_name)
    primary = Settings.Schema.get_dotted(settings, "model_preferences.primary")

    candidates =
      preference_candidates(preference_profiles) ++ primary_fallback(preference_profiles, primary)

    candidates
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.reduce({[], []}, fn candidate, {resolutions, diagnostics} ->
      case validate_candidate(candidate, capability, settings) do
        {:ok, profile, source} ->
          resolution = %{
            request: request_name,
            request_kind: request_kind,
            capability: capability,
            profile: profile,
            profile_name: profile.name,
            source: source,
            diagnostics: Enum.reverse(diagnostics)
          }

          {[resolution | resolutions], diagnostics}

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

  defp validate_candidate({profile_name, source}, capability, settings) do
    with {:ok, attrs} <- fetch_profile_attrs(profile_name, settings),
         :ok <- validate_profile_capability(profile_name, attrs, capability),
         :ok <- validate_provider_enabled(profile_name, attrs, settings),
         {:ok, profile} <- Settings.resolve_model_profile(profile_name) do
      {:ok, profile, source}
    else
      {:error, reason} -> {:skip, diagnostic(profile_name, reason)}
    end
  end

  defp fetch_profile_attrs(profile_name, settings) do
    case get_in(settings, ["model_profiles", profile_name]) do
      attrs when is_map(attrs) -> {:ok, attrs}
      _missing -> {:error, :missing_profile}
    end
  end

  defp validate_profile_capability(profile_name, attrs, capability) do
    capabilities = Map.get(attrs, "capabilities", [])

    if capability in capabilities do
      :ok
    else
      {:error, {:profile_missing_capability, profile_name, capability}}
    end
  end

  defp validate_provider_enabled(profile_name, attrs, settings) do
    provider = Map.get(attrs, "provider")

    case get_in(settings, ["providers", provider]) do
      %{"enabled" => true} -> :ok
      %{"enabled" => false} -> {:error, {:provider_disabled, profile_name, provider}}
      _missing -> {:error, {:provider_missing, profile_name, provider}}
    end
  end

  defp diagnostic(profile_name, reason) do
    %{
      profile: profile_name,
      status: :skipped,
      reason: reason
    }
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
