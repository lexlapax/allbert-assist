defmodule AllbertAssist.Intent.Engine do
  @moduledoc """
  Registry-aware intent engine entrypoint.

  M1 keeps behavior conservative: it can produce a direct-answer decision and
  annotate existing decisions with bounded candidate metadata. Later v0.19
  milestones add real registry collection, app/surface ranking, and optional
  model assistance behind this module.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Intent.Candidate
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.Ranker
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills

  @spec decide(map()) :: {:ok, Decision.t()} | {:error, term()}
  def decide(request) when is_map(request) do
    app_context = active_app_context(request)

    attrs =
      case surface_navigation_candidate(request) do
        nil -> direct_answer_attrs(request, app_context)
        surface -> surface_navigation_attrs(surface, request, app_context)
      end

    with {:ok, decision} <- Decision.new(attrs) do
      {:ok, put_candidate_metadata(decision, %{request: request})}
    end
  end

  def decide(value), do: {:error, {:invalid_request, value}}

  @spec put_candidate_metadata(Decision.t(), map()) :: Decision.t()
  def put_candidate_metadata(%Decision{} = decision, context) do
    request = request_from_context(context)
    selected = selected_candidate(decision)

    candidates =
      request
      |> collect_candidates()
      |> include_selected(selected)
      |> Ranker.rank(request)
      |> Candidate.bound(total_limit: max_candidates())

    rejected =
      candidates
      |> Enum.reject(&(field(&1, :id) == selected.id and field(&1, :kind) == selected.kind))
      |> Enum.map(&Candidate.to_map/1)

    trace_metadata =
      decision.trace_metadata
      |> Map.put(:active_app, normalized_active_app(request))
      |> Map.put(:intent_candidates, %{
        selected: selected |> Candidate.to_map(),
        rejected: rejected,
        total: length(candidates),
        engine_version: "v0.19-m2"
      })

    %{decision | trace_metadata: trace_metadata}
  end

  @spec put_candidate_metadata(Decision.t()) :: Decision.t()
  def put_candidate_metadata(%Decision{} = decision), do: put_candidate_metadata(decision, %{})

  @spec annotate_response(map()) :: map()
  def annotate_response(%{} = response) do
    case Map.get(response, :decision) || Map.get(response, "decision") do
      %Decision{} = decision -> Map.put(response, :decision, put_candidate_metadata(decision))
      _other -> response
    end
  end

  @spec collect_candidates(map()) :: [Candidate.t()]
  def collect_candidates(request) when is_map(request) do
    request
    |> do_collect_candidates()
    |> Candidate.bound(total_limit: max_candidates())
  end

  def collect_candidates(_request), do: []

  defp direct_answer_attrs(request, app_context) do
    %{
      intent: :direct_answer,
      reason: "The prompt is handled by the default direct-answer route.",
      selected_skill: "direct-answer",
      selected_action: "direct_answer",
      active_app: app_context.active_app,
      diagnostics: app_context.diagnostics,
      trace_metadata: %{source_text: field(request, :text)},
      context: %{request: request}
    }
  end

  defp surface_navigation_attrs(surface, request, app_context) do
    surface_target = surface_target(surface)

    %{
      intent: :open_surface,
      confidence: Ranker.score(surface),
      reason: "The request matched a registered app surface.",
      selected_skill: nil,
      selected_action: nil,
      active_app: app_context.active_app,
      diagnostics: app_context.diagnostics,
      trace_metadata: %{
        source_text: field(request, :text),
        surface_target: surface_target,
        ranking_reason: get_in_trace(surface, :ranking_reason)
      },
      context: %{request: request}
    }
  end

  defp surface_navigation_candidate(request) do
    request
    |> collect_candidates()
    |> Ranker.rank(request)
    |> Enum.find(fn candidate ->
      field(candidate, :kind) == :surface and
        get_in_trace(candidate, :ranking_reason) == :surface_text_match
    end)
  end

  defp selected_candidate(%Decision{intent: :open_surface} = decision) do
    case field(decision.trace_metadata, :surface_target) do
      %{} = surface ->
        Candidate.new!(%{
          kind: :surface,
          id: field(surface, :id),
          label: field(surface, :label),
          source: :app,
          status: :selected,
          selected?: true,
          score: 1.0,
          reason: "Selected registered surface #{field(surface, :label)}.",
          surface_id: field(surface, :surface_id),
          app_id: field(surface, :app_id),
          trace_metadata: surface
        })

      _other ->
        Candidate.selected_from_decision(decision)
    end
  end

  defp selected_candidate(%Decision{} = decision), do: Candidate.selected_from_decision(decision)

  defp do_collect_candidates(request) do
    action_candidates() ++ skill_candidates(request) ++ surface_candidates()
  end

  defp action_candidates do
    ActionsRegistry.agent_capabilities()
    |> Enum.map(&candidate_from_capability/1)
    |> Enum.reject(&is_nil/1)
  end

  defp candidate_from_capability(%Capability{} = capability) do
    Candidate.new!(%{
      kind: :action,
      id: capability.name,
      label: capability.name,
      source: provenance_source(capability),
      status: :candidate,
      score: 0.25,
      reason: "Registered action #{capability.name}.",
      action_name: capability.name,
      app_id: capability.app_id,
      plugin_id: capability.plugin_id,
      permission: capability.permission,
      execution_mode: capability.execution_mode,
      confirmation: capability.confirmation,
      trace_metadata: Capability.summary(capability)
    })
  rescue
    _exception -> nil
  end

  defp skill_candidates(request) do
    {:ok, skills} = Skills.list(%{request: request})

    skills
    |> Enum.map(&candidate_from_skill/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _exception -> []
  end

  defp candidate_from_skill(skill) do
    Candidate.new!(%{
      kind: :skill,
      id: skill.name,
      label: skill.title,
      source: skill_source(skill),
      status: :candidate,
      score: 0.2,
      reason: "Trusted skill #{skill.name}.",
      skill_name: skill.name,
      plugin_id: Map.get(skill, :plugin_id),
      permission: Map.get(skill, :permission),
      trace_metadata: %{
        source_scope: skill.source_scope,
        trust_status: skill.trust_status,
        kind: skill.kind,
        activation_mode: skill.activation_mode
      }
    })
  rescue
    _exception -> nil
  end

  defp surface_candidates do
    AppRegistry.registered_surfaces()
    |> Enum.map(&candidate_from_surface/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  defp candidate_from_surface(surface) do
    id = field(surface, :id)
    app_id = field(surface, :app_id)
    path = field(surface, :path)
    label = field(surface, :label) || to_string(id)

    Candidate.new!(%{
      kind: :surface,
      id: "#{app_id}:#{id}",
      label: label,
      source: :app,
      status: :candidate,
      score: 0.15,
      reason: "Registered app surface #{label}.",
      surface_id: id,
      app_id: app_id,
      trace_metadata: %{
        path: path,
        kind: field(surface, :kind),
        provider?: field(surface, :provider?, false),
        status: field(surface, :status)
      }
    })
  rescue
    _exception -> nil
  end

  defp include_selected(candidates, selected) do
    candidates =
      Enum.reject(candidates, fn candidate ->
        field(candidate, :kind) == selected.kind and field(candidate, :id) == selected.id
      end)

    [selected | candidates]
  end

  defp surface_target(surface) do
    %{
      id: field(surface, :id),
      label: field(surface, :label),
      app_id: field(surface, :app_id),
      surface_id: field(surface, :surface_id),
      path: get_in_trace(surface, :path),
      kind: get_in_trace(surface, :kind),
      provider?: get_in_trace(surface, :provider?)
    }
  end

  defp active_app_context(request) do
    requested = field(request, :active_app) || field(request, :app_id)
    do_active_app_context(requested)
  end

  defp do_active_app_context(requested) do
    case AppRegistry.normalize_app_id(requested) do
      {:ok, nil} ->
        %{active_app: :allbert, diagnostics: []}

      {:ok, app_id} ->
        %{active_app: app_id, diagnostics: []}

      {:error, reason} ->
        %{
          active_app: :allbert,
          diagnostics: [
            %{
              source: :active_app,
              kind: :unknown_app_id,
              app_id: inspect(requested),
              fallback: :allbert,
              reason: reason
            }
          ]
        }
    end
  catch
    :exit, reason ->
      %{
        active_app: :allbert,
        diagnostics: [
          %{
            source: :active_app,
            kind: :unknown_app_id,
            app_id: inspect(requested),
            fallback: :allbert,
            reason: reason
          }
        ]
      }
  end

  defp normalized_active_app(request), do: active_app_context(request).active_app

  defp get_in_trace(candidate, key) do
    candidate
    |> field(:trace_metadata, %{})
    |> field(key)
  end

  defp request_from_context(%{request: request}) when is_map(request), do: request
  defp request_from_context(%{"request" => request}) when is_map(request), do: request
  defp request_from_context(context) when is_map(context), do: context
  defp request_from_context(_context), do: %{}

  defp provenance_source(%Capability{plugin_id: plugin_id}) when is_binary(plugin_id), do: :plugin
  defp provenance_source(%Capability{app_id: app_id}) when is_atom(app_id), do: :app
  defp provenance_source(_capability), do: :registry

  defp skill_source(%{source_scope: :plugin}), do: :plugin
  defp skill_source(%{source_scope: :app}), do: :app
  defp skill_source(%{source_scope: :built_in}), do: :registry
  defp skill_source(%{source_scope: :built_in_legacy}), do: :registry
  defp skill_source(_skill), do: :registry

  defp max_candidates do
    case Settings.get("intent.max_candidates") do
      {:ok, value} when is_integer(value) -> value
      _other -> 80
    end
  rescue
    _exception -> 80
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
