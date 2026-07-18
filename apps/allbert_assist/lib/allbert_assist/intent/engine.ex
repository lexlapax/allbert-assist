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
  alias AllbertAssist.Channels
  alias AllbertAssist.Intent.Candidate
  alias AllbertAssist.Intent.Classifier
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Intent.Handoff
  alias AllbertAssist.Intent.Ranker
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Jobs
  alias AllbertAssist.Maps
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Index, as: MemoryIndex
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills

  @spec decide(map(), keyword()) :: {:ok, Decision.t()} | {:error, term()}
  def decide(request, opts \\ [])

  # v1.0.2 M8.4: each decide clause pins ONE turn-scoped resolved-settings
  # snapshot (safety pin — IntentAgent.respond/1 pins the full turn and this
  # nests as a no-op), so the dozens of Settings reads under one decide
  # (flags, thresholds, classifier/router tuning) share a single ~44-48ms
  # resolution instead of one each.
  def decide(%{route_decision: %Decision{} = decision} = request, opts) when is_map(request) do
    Settings.with_resolved_settings(fn ->
      if explicit_route_hint?(request) do
        {:ok,
         put_candidate_metadata(decision, metadata_context(request, RegistryContext.take(opts)))}
      else
        decide_without_explicit_route(request, opts)
      end
    end)
  end

  def decide(request, opts) when is_map(request) do
    Settings.with_resolved_settings(fn ->
      decide_without_explicit_route(request, opts)
    end)
  end

  def decide(value, _opts), do: {:error, {:invalid_request, value}}

  defp decide_without_explicit_route(request, opts) do
    registry = RegistryContext.take(opts)
    app_context = active_app_context(request, registry)
    # v1.0.2 M8.2: collect_candidates/2 already ranks and bounds its output;
    # the former ranked_candidates/2 re-rank+re-bound was a measured hot-path
    # no-op (M1 made the ranking boosts idempotent).
    candidates = collect_candidates(request, registry)
    {classifier_candidate, classifier_diagnostic} = classifier_candidate(candidates, request)

    attrs =
      descriptor_decision_attrs(
        candidates,
        request,
        app_context,
        classifier_diagnostic,
        classifier_candidate,
        registry
      ) ||
        descriptor_action_attrs(
          candidates,
          request,
          app_context,
          classifier_diagnostic,
          classifier_candidate,
          registry
        ) ||
        case selected_route_candidate(classifier_candidate, candidates, request) do
          nil ->
            direct_answer_attrs(request, app_context, classifier_diagnostic)

          candidate ->
            decision_attrs_for_candidate(
              candidate,
              request,
              app_context,
              classifier_diagnostic,
              registry
            )
        end

    with {:ok, decision} <- build_decision(attrs, request, classifier_diagnostic, registry) do
      {:ok, put_candidate_metadata(decision, metadata_context(request, registry))}
    end
  end

  @spec put_candidate_metadata(Decision.t(), map()) :: Decision.t()
  def put_candidate_metadata(%Decision{} = decision, context) do
    request = request_from_context(context)
    registry = registry_opts(context)
    collected_candidates = collect_candidates(request, objective_opts(context) ++ registry)
    selected = selected_candidate(decision, collected_candidates, registry)

    # v1.0.2 M8.2: collected_candidates is already ranked and bounded;
    # include_selected/2 places the selected candidate at the head — exactly
    # where the former Ranker.rank re-pass sorted it (its selected?/status
    # sort boosts always order the selected candidate first) — so no re-rank
    # (and no re-applied boosts) is needed to preserve order.
    candidates =
      collected_candidates
      |> include_selected(selected)
      |> Candidate.bound(total_limit: max_candidates())

    rejected = rejected_candidates(candidates, selected)

    trace_metadata =
      decision.trace_metadata
      |> Map.put(:active_app, normalized_active_app(request, registry))
      |> Map.put(:intent_candidates, %{
        selected: selected |> Candidate.to_map(),
        rejected: rejected,
        descriptors: descriptor_candidate_maps(candidates),
        memory: memory_candidate_maps(candidates),
        objectives: objective_candidate_maps(candidates),
        total: length(candidates),
        engine_version: "v0.19"
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
    collect_candidates(request, [])
  end

  def collect_candidates(_request), do: []

  @spec collect_candidates(map(), keyword()) :: [Candidate.t()]
  def collect_candidates(request, opts) when is_map(request) and is_list(opts) do
    request
    |> do_collect_candidates(opts)
    |> Ranker.rank(request)
    |> Candidate.bound(total_limit: max_candidates())
  end

  def collect_candidates(_request, _opts), do: []

  defp direct_answer_attrs(request, app_context, classifier_diagnostic) do
    %{
      intent: :direct_answer,
      reason: "The prompt is handled by the default direct-answer route.",
      selected_skill: "direct-answer",
      selected_action: "direct_answer",
      active_app: app_context.active_app,
      diagnostics: app_context.diagnostics,
      trace_metadata:
        %{source_text: field(request, :text)} |> put_classifier(classifier_diagnostic),
      context: %{request: request}
    }
  end

  defp decision_attrs_for_candidate(
         %{kind: :surface} = surface,
         request,
         app_context,
         classifier_diagnostic,
         _registry
       ) do
    surface_navigation_attrs(surface, request, app_context, classifier_diagnostic)
  end

  defp decision_attrs_for_candidate(
         %{kind: :action} = candidate,
         request,
         app_context,
         classifier_diagnostic,
         _registry
       ) do
    %{
      intent: :registry_action,
      confidence: Ranker.score(candidate),
      reason: field(candidate, :reason),
      selected_action: field(candidate, :action_name),
      active_app: app_context.active_app,
      diagnostics: app_context.diagnostics,
      trace_metadata:
        %{
          source_text: field(request, :text),
          classifier_selected?: not is_nil(classifier_diagnostic)
        }
        |> put_route_hint(candidate)
        |> put_classifier(classifier_diagnostic),
      context: %{request: request}
    }
  end

  defp decision_attrs_for_candidate(
         %{kind: :skill} = candidate,
         request,
         app_context,
         classifier_diagnostic,
         _registry
       ) do
    %{
      intent: :registry_skill,
      confidence: Ranker.score(candidate),
      reason: field(candidate, :reason),
      selected_skill: field(candidate, :skill_name),
      active_app: app_context.active_app,
      diagnostics: app_context.diagnostics,
      trace_metadata:
        %{
          source_text: field(request, :text),
          classifier_selected?: not is_nil(classifier_diagnostic)
        }
        |> put_route_hint(candidate)
        |> put_classifier(classifier_diagnostic),
      context: %{request: request}
    }
  end

  defp decision_attrs_for_candidate(
         %{kind: :memory} = candidate,
         request,
         app_context,
         classifier_diagnostic,
         _registry
       ) do
    %{
      intent: field(candidate, :trace_metadata, %{}) |> field(:intent, :direct_answer),
      confidence: Ranker.score(candidate),
      reason: field(candidate, :reason),
      selected_skill: field(candidate, :skill_name),
      selected_action: field(candidate, :action_name),
      active_app: app_context.active_app,
      diagnostics: app_context.diagnostics,
      trace_metadata:
        %{
          source_text: field(request, :text),
          candidate_kind: :memory,
          classifier_selected?: not is_nil(classifier_diagnostic)
        }
        |> put_classifier(classifier_diagnostic),
      context: %{request: request}
    }
  end

  defp decision_attrs_for_candidate(
         %{kind: :objective} = candidate,
         request,
         app_context,
         classifier_diagnostic,
         _registry
       ) do
    %{
      intent: :continue_objective,
      confidence: Ranker.score(candidate),
      reason: field(candidate, :reason),
      active_app: app_context.active_app,
      diagnostics: app_context.diagnostics,
      trace_metadata:
        %{
          source_text: field(request, :text),
          candidate_kind: :objective,
          objective_id: field(candidate, :id),
          objective_candidate: Candidate.to_map(candidate),
          classifier_selected?: not is_nil(classifier_diagnostic)
        }
        |> put_classifier(classifier_diagnostic),
      context: %{request: request}
    }
  end

  defp decision_attrs_for_candidate(
         %{kind: :app_intent} = candidate,
         request,
         app_context,
         classifier_diagnostic,
         registry
       ) do
    descriptor_decision_attrs(
      [candidate],
      request,
      app_context,
      classifier_diagnostic,
      candidate,
      registry
    ) ||
      direct_answer_attrs(request, app_context, classifier_diagnostic)
  end

  defp decision_attrs_for_candidate(
         %{kind: kind} = candidate,
         request,
         app_context,
         classifier_diagnostic,
         _registry
       )
       when kind in [:job, :channel, :refusal] do
    %{
      intent: field(candidate, :trace_metadata, %{}) |> field(:intent, :direct_answer),
      confidence: Ranker.score(candidate),
      reason: field(candidate, :reason),
      selected_action: field(candidate, :action_name),
      active_app: app_context.active_app,
      diagnostics: app_context.diagnostics,
      trace_metadata:
        %{
          source_text: field(request, :text),
          candidate_kind: kind,
          candidate_id: field(candidate, :id),
          classifier_selected?: not is_nil(classifier_diagnostic)
        }
        |> put_classifier(classifier_diagnostic),
      context: %{request: request}
    }
  end

  defp decision_attrs_for_candidate(
         _candidate,
         request,
         app_context,
         classifier_diagnostic,
         _registry
       ) do
    direct_answer_attrs(request, app_context, classifier_diagnostic)
  end

  defp surface_navigation_attrs(surface, request, app_context, classifier_diagnostic) do
    surface_target = surface_target(surface)

    %{
      intent: :open_surface,
      confidence: Ranker.score(surface),
      reason: "The request matched a registered app surface.",
      selected_skill: nil,
      selected_action: nil,
      active_app: app_context.active_app,
      diagnostics: app_context.diagnostics,
      trace_metadata:
        %{
          source_text: field(request, :text),
          surface_target: surface_target,
          ranking_reason: get_in_trace(surface, :ranking_reason)
        }
        |> put_classifier(classifier_diagnostic),
      context: %{request: request}
    }
  end

  defp selected_route_candidate(classifier_candidate, candidates, request) do
    classifier_candidate ||
      surface_navigation_candidate(candidates, request) ||
      route_hint_candidate(candidates) ||
      deterministic_candidate(candidates)
  end

  defp surface_navigation_candidate(candidates, request) do
    if route_hint_direct_answer?(request) do
      candidates
      |> Enum.find(fn candidate ->
        field(candidate, :kind) == :surface and
          get_in_trace(candidate, :ranking_reason) == :surface_text_match
      end)
    end
  end

  defp route_hint_candidate(candidates) do
    Enum.find(candidates, &(get_in_trace(&1, :engine_route_hint?) == true))
  end

  defp deterministic_candidate(candidates) do
    Enum.find(candidates, fn candidate ->
      reason = get_in_trace(candidate, :ranking_reason)

      # v0.22 audit closeout (gap 2): when the active-app boost is the
      # only reason a candidate ranked, it's still selectable as long as
      # it's a registered action or skill candidate. Surfaces, memories,
      # channels, jobs, and refusals require an explicit text-match reason
      # to be picked; otherwise active-app context could silently route to
      # an unintended surface or memory entry.
      reason in [
        :action_text_match,
        :skill_text_match,
        :job_text_match,
        :channel_text_match,
        :memory_keyword_match,
        :objective_text_match,
        :refusal_keyword_match
      ] or
        (reason == :app_affinity and field(candidate, :kind) in [:action, :skill])
    end)
  end

  defp classifier_candidate(candidates, request) do
    if classifier_allowed?(request) do
      case Classifier.classify(candidates, request) do
        {:ok, %{candidate: candidate, diagnostic: diagnostic}} -> {candidate, diagnostic}
        {:error, %{status: :disabled}} -> {nil, nil}
        {:error, diagnostic} -> {nil, diagnostic}
      end
    else
      {nil, nil}
    end
  end

  defp selected_candidate(%Decision{} = decision, candidates, registry)
       when is_list(candidates) do
    case route_hint_candidate(candidates) do
      %{id: id, kind: kind} = candidate ->
        selected = Candidate.selected_from_decision(decision, registry)

        if selected.id == id and selected.kind == kind do
          candidate
        else
          selected_candidate(decision, registry)
        end

      nil ->
        selected_candidate(decision, registry)
    end
  end

  defp selected_candidate(%Decision{intent: :open_surface} = decision, registry) do
    case field(decision.trace_metadata, :surface_target) do
      %{} = surface ->
        Candidate.new!(
          %{
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
          },
          registry
        )

      _other ->
        Candidate.selected_from_decision(decision, registry)
    end
  end

  defp selected_candidate(%Decision{intent: intent} = decision, registry)
       when intent in [:app_handoff, :clarify_intent] do
    handoff = field(decision.trace_metadata, :intent_handoff, %{})

    Candidate.new!(
      %{
        kind: :app_intent,
        id:
          field(handoff, :candidate_id) ||
            "#{field(handoff, :app_id)}:#{field(handoff, :action_name)}",
        label: field(handoff, :label),
        source: :app,
        status: :selected,
        selected?: true,
        score: decision.confidence,
        reason: decision.reason,
        action_name: field(handoff, :action_name),
        app_id: field(handoff, :app_id),
        permission: field(handoff, :permission),
        execution_mode: field(handoff, :execution_mode),
        confirmation: field(handoff, :confirmation),
        trace_metadata: %{intent: intent, intent_handoff: handoff}
      },
      registry
    )
  rescue
    _exception -> Candidate.selected_from_decision(decision, registry)
  end

  defp selected_candidate(%Decision{} = decision, registry),
    do: Candidate.selected_from_decision(decision, registry)

  defp do_collect_candidates(request, opts) do
    registry = RegistryContext.take(opts)

    route_hint_candidates(request, registry) ++
      action_candidates(request, registry) ++
      descriptor_candidates(request, registry) ++
      surface_candidates(registry) ++
      relevant_job_candidates(request, registry) ++
      relevant_channel_candidates(request, registry) ++
      memory_candidates(request) ++
      objective_candidates(request, Keyword.get(opts, :objective), registry) ++
      refusal_candidates(request) ++
      relevant_skill_candidates(request, registry)
  end

  defp descriptor_candidates(request, registry) do
    if descriptors_enabled?() do
      registry
      |> DescriptorResolver.resolve()
      |> Enum.map(&candidate_from_descriptor(&1, request, registry))
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  defp descriptor_decision_attrs(
         candidates,
         request,
         app_context,
         classifier_diagnostic,
         classifier_candidate,
         registry
       ) do
    with true <- descriptors_enabled?(),
         true <- neutral_app?(app_context.active_app),
         [%{} = top | _rest] <-
           descriptor_candidates_for_decision(candidates, classifier_candidate),
         score <- Ranker.score(top),
         true <- score >= clarify_floor() do
      if registered_descriptor_candidate?(top),
        do:
          registered_descriptor_attrs(
            top,
            candidates,
            request,
            app_context,
            classifier_diagnostic,
            registry
          ),
        else:
          descriptor_handoff_attrs(
            top,
            candidates,
            request,
            app_context,
            classifier_diagnostic,
            registry
          )
    else
      _no_descriptor_action -> nil
    end
  end

  defp registered_descriptor_attrs(
         top,
         candidates,
         request,
         app_context,
         classifier_diagnostic,
         registry
       ) do
    case descriptor_action_kind(top) do
      :registry_action ->
        descriptor_registry_action_attrs(top, request, app_context, classifier_diagnostic)

      :clarify_intent ->
        descriptor_clarification_attrs(
          top,
          candidates,
          request,
          app_context,
          classifier_diagnostic,
          registry
        )
    end
  end

  defp descriptor_handoff_attrs(
         candidate,
         candidates,
         request,
         app_context,
         classifier_diagnostic,
         registry
       ) do
    with {:ok, handoff} <-
           Handoff.new(
             handoff_attrs(
               descriptor_decision_kind(candidate, candidates),
               candidate,
               request,
               descriptor_margin(candidate, candidates)
             ),
             registry
           ) do
      %{
        intent: handoff.kind,
        confidence: handoff.confidence,
        reason: handoff.reason,
        selected_action: nil,
        active_app: app_context.active_app,
        diagnostics: app_context.diagnostics,
        trace_metadata:
          %{
            source_text: field(request, :text),
            candidate_kind: :app_intent,
            intent_handoff: Handoff.to_map(handoff),
            classifier_selected?: not is_nil(classifier_diagnostic)
          }
          |> put_classifier(classifier_diagnostic),
        context: %{request: request}
      }
    else
      _no_descriptor_handoff -> nil
    end
  end

  defp descriptor_action_attrs(
         candidates,
         request,
         app_context,
         classifier_diagnostic,
         classifier_candidate,
         registry
       ) do
    with true <- descriptors_enabled?(),
         false <- neutral_app?(app_context.active_app),
         [%{} = top | _rest] <-
           descriptor_candidates_for_decision(candidates, classifier_candidate),
         true <- field(top, :app_id) == app_context.active_app,
         true <- get_in_trace(top, :ranking_reason) == :descriptor_text_match,
         score <- Ranker.score(top),
         true <- score >= clarify_floor(),
         true <- registered_descriptor_candidate?(top) do
      case descriptor_action_kind(top) do
        :registry_action ->
          descriptor_registry_action_attrs(top, request, app_context, classifier_diagnostic)

        :clarify_intent ->
          descriptor_clarification_attrs(
            top,
            candidates,
            request,
            app_context,
            classifier_diagnostic,
            registry
          )
      end
    else
      _no_descriptor_action -> nil
    end
  end

  defp descriptor_registry_action_attrs(candidate, request, app_context, classifier_diagnostic) do
    trace_metadata = field(candidate, :trace_metadata, %{})
    descriptor = field(trace_metadata, :descriptor, %{})

    %{
      intent: :registry_action,
      confidence: Ranker.score(candidate),
      reason: "Request matched #{field(candidate, :label)} in the active app context.",
      selected_action: field(candidate, :action_name),
      active_app: app_context.active_app,
      diagnostics: app_context.diagnostics,
      trace_metadata:
        %{
          source_text: field(request, :text),
          app_id: field(candidate, :app_id),
          candidate_kind: :app_intent,
          descriptor: descriptor,
          descriptor_candidate_id: field(candidate, :id),
          extracted_slots: get_in_trace(candidate, :extracted_slots) || %{},
          missing_slots: get_in_trace(candidate, :missing_slots) || [],
          classifier_selected?: not is_nil(classifier_diagnostic)
        }
        |> put_classifier(classifier_diagnostic),
      context: %{request: request}
    }
  end

  defp descriptor_clarification_attrs(
         candidate,
         candidates,
         request,
         app_context,
         classifier_diagnostic,
         registry
       ) do
    with {:ok, handoff} <-
           Handoff.new(
             handoff_attrs(
               :clarify_intent,
               candidate,
               request,
               descriptor_margin(candidate, candidates)
             ),
             registry
           ) do
      %{
        intent: :clarify_intent,
        confidence: handoff.confidence,
        reason: handoff.reason,
        selected_action: nil,
        active_app: app_context.active_app,
        diagnostics: app_context.diagnostics,
        trace_metadata:
          %{
            source_text: field(request, :text),
            candidate_kind: :app_intent,
            intent_handoff: Handoff.to_map(handoff),
            classifier_selected?: not is_nil(classifier_diagnostic)
          }
          |> put_classifier(classifier_diagnostic),
        context: %{request: request}
      }
    else
      _reason -> nil
    end
  end

  defp descriptor_candidates_for_decision(candidates, classifier_candidate \\ nil) do
    descriptors =
      candidates
      |> Enum.filter(&(field(&1, :kind) == :app_intent))
      |> Enum.sort_by(&Ranker.score/1, :desc)

    case descriptor_selected_by_classifier(descriptors, classifier_candidate) do
      nil ->
        descriptors

      selected ->
        [selected | Enum.reject(descriptors, &(field(&1, :id) == field(selected, :id)))]
    end
  end

  defp descriptor_selected_by_classifier(descriptors, %{kind: :app_intent} = candidate) do
    Enum.find(descriptors, &(field(&1, :id) == field(candidate, :id)))
  end

  defp descriptor_selected_by_classifier(descriptors, %{kind: :action} = candidate) do
    Enum.find(descriptors, fn descriptor ->
      field(descriptor, :app_id) == field(candidate, :app_id) and
        field(descriptor, :action_name) == field(candidate, :action_name)
    end)
  end

  defp descriptor_selected_by_classifier(_descriptors, _candidate), do: nil

  defp descriptor_decision_kind(candidate, candidates) do
    missing_slots = get_in_trace(candidate, :missing_slots) || []
    score = Ranker.score(candidate)
    margin = descriptor_margin(candidate, candidates)

    cond do
      missing_slots != [] ->
        :clarify_intent

      score >= handoff_threshold() and margin >= handoff_margin() ->
        :app_handoff

      true ->
        :clarify_intent
    end
  end

  defp descriptor_action_kind(candidate) do
    case get_in_trace(candidate, :missing_slots) || [] do
      [] -> :registry_action
      _missing -> :clarify_intent
    end
  end

  defp registered_descriptor_candidate?(candidate) do
    trace_metadata = field(candidate, :trace_metadata, %{})
    descriptor = field(trace_metadata, :descriptor, %{})
    capability = field(descriptor, :capability, %{})

    field(capability, :registered?, true) == true
  end

  defp descriptor_margin(candidate, candidates) do
    score = Ranker.score(candidate)

    candidates
    |> descriptor_candidates_for_decision()
    |> Enum.reject(&(field(&1, :id) == field(candidate, :id)))
    |> Enum.map(&Ranker.score/1)
    |> List.first()
    |> case do
      value when is_float(value) -> max(score - value, 0.0)
      _none -> 1.0
    end
  end

  defp handoff_attrs(kind, candidate, request, margin) do
    trace_metadata = field(candidate, :trace_metadata, %{})
    descriptor = field(trace_metadata, :descriptor, %{})

    %{
      kind: kind,
      app_id: field(candidate, :app_id),
      action_name: field(candidate, :action_name),
      label: field(candidate, :label) || field(descriptor, :label) || field(candidate, :id),
      candidate_id: field(candidate, :id),
      source_text: field(request, :text),
      reason: descriptor_reason(kind, candidate),
      confidence: Ranker.score(candidate),
      margin: margin,
      permission: field(candidate, :permission),
      execution_mode: field(candidate, :execution_mode),
      confirmation: field(candidate, :confirmation),
      destination: field(descriptor, :destination),
      extracted_slots: get_in_trace(candidate, :extracted_slots) || %{},
      missing_slots: get_in_trace(candidate, :missing_slots) || [],
      descriptor: descriptor,
      options: descriptor_options(candidate)
    }
  end

  defp descriptor_reason(:app_handoff, candidate) do
    "Request matched #{field(candidate, :label)} and all required slots were present."
  end

  defp descriptor_reason(:clarify_intent, candidate) do
    missing_slots = get_in_trace(candidate, :missing_slots) || []

    if missing_slots == [] do
      "Request matched an app intent descriptor but needs operator clarification."
    else
      "Request matched #{field(candidate, :label)} but is missing #{Enum.join(missing_slots, ", ")}."
    end
  end

  defp descriptor_options(candidate) do
    trace_metadata = field(candidate, :trace_metadata, %{})
    descriptor = field(trace_metadata, :descriptor, %{})

    [
      %{
        app_id: field(candidate, :app_id),
        action_name: field(candidate, :action_name),
        label: field(candidate, :label),
        candidate_id: field(candidate, :id),
        destination: field(descriptor, :destination)
      }
    ]
  end

  defp candidate_from_descriptor(descriptor, request, registry) do
    slots = Descriptor.extract_slots(descriptor, field(request, :text) || "")
    capability = descriptor.capability

    Candidate.new!(
      %{
        kind: :app_intent,
        id: descriptor.id,
        label: descriptor.label,
        source: descriptor.source || :app,
        status: :candidate,
        score: 0.2,
        reason: "App intent descriptor #{descriptor.label}.",
        action_name: descriptor.action_name,
        app_id: descriptor.app_id,
        plugin_id: Map.get(capability, :plugin_id),
        permission: Map.get(capability, :permission),
        execution_mode: Map.get(capability, :execution_mode),
        confirmation: Map.get(capability, :confirmation),
        trace_metadata: %{
          intent: :app_intent,
          descriptor: Descriptor.to_map(descriptor),
          extracted_slots: slots.extracted_slots,
          missing_slots: slots.missing_slots,
          handoff_required?: descriptor.handoff_required?
        }
      },
      registry
    )
  rescue
    _exception -> nil
  end

  defp action_candidates(request, registry) do
    registry
    |> ActionsRegistry.agent_capabilities()
    |> Enum.map(&candidate_from_capability(&1, request, registry))
    |> Enum.reject(&is_nil/1)
  end

  defp candidate_from_capability(%Capability{} = capability, request, registry) do
    Candidate.new!(
      %{
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
        resource_access: action_resource_access(capability, request),
        trace_metadata: Capability.summary(capability)
      },
      registry
    )
  rescue
    _exception -> nil
  end

  defp route_hint_candidates(
         %{route_decision: %Decision{} = decision, route_hint: route_hint},
         registry
       ) do
    selected = Candidate.selected_from_decision(decision, registry)

    [
      %{
        selected
        | score: 1.0,
          source: :deterministic,
          reason: "Selected by the deterministic IntentAgent route candidate.",
          trace_metadata: %{
            engine_route_hint?: true,
            route: field(route_hint, :route),
            explicit?: field(route_hint, :explicit?, false),
            source: field(route_hint, :source)
          }
      }
    ]
  rescue
    _exception -> []
  end

  defp route_hint_candidates(_request, _registry), do: []

  defp skill_candidates(request, registry) do
    {:ok, skills} = Skills.list(skills_context(request, registry))

    skills
    |> Enum.map(&candidate_from_skill/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _exception -> []
  end

  defp relevant_skill_candidates(request, registry) do
    if skill_candidates_relevant?(request), do: skill_candidates(request, registry), else: []
  end

  # Only annotate the skills context with the internal registry keyword when a
  # caller provided one, so the default path stays identical.
  defp skills_context(request, []), do: %{request: request}
  defp skills_context(request, registry), do: %{request: request, registry: registry}

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

  defp surface_candidates(registry) do
    registry
    |> RegistryContext.app_opts()
    |> AppRegistry.registered_surfaces()
    |> Enum.map(&candidate_from_surface(&1, registry))
    |> Enum.reject(&is_nil/1)
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  defp candidate_from_surface(surface, registry) do
    id = field(surface, :id)
    app_id = field(surface, :app_id)
    path = field(surface, :path)
    label = field(surface, :label) || to_string(id)

    Candidate.new!(
      %{
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
      },
      registry
    )
  rescue
    _exception -> nil
  end

  defp job_candidates(request, registry) do
    user_id = field(request, :user_id) || field(request, :operator_id) || "local"

    user_id
    |> Jobs.list_jobs(limit: 10)
    |> Enum.map(&candidate_from_job(&1, registry))
    |> Enum.reject(&is_nil/1)
  rescue
    _exception -> []
  end

  defp relevant_job_candidates(request, registry) do
    text = field(request, :text) || ""

    if job_text?(text), do: job_candidates(request, registry), else: []
  end

  defp candidate_from_job(job, registry) do
    Candidate.new!(
      %{
        kind: :job,
        id: job.id,
        label: job.name,
        source: :job,
        status: :candidate,
        score: 0.18,
        reason: "Scheduled job #{job.name}.",
        job_id: job.id,
        app_id: app_id_from_string(job.app_id, registry),
        trace_metadata: %{
          status: job.status,
          target_type: job.target_type,
          schedule_kind: field(job.schedule, :kind),
          thread_mode: job.thread_mode
        }
      },
      registry
    )
  rescue
    _exception -> nil
  end

  defp channel_candidates(registry) do
    registry
    |> RegistryContext.plugin_opts()
    |> Channels.list_channels()
    |> Enum.map(&candidate_from_channel/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _exception -> []
  end

  defp relevant_channel_candidates(request, registry) do
    text = field(request, :text) || ""

    if channel_text?(text), do: channel_candidates(registry), else: []
  end

  defp candidate_from_channel(channel) do
    channel_id = field(channel, :channel)

    Candidate.new!(%{
      kind: :channel,
      id: channel_id,
      label: field(channel, :provider) || channel_id,
      source: :channel,
      status: :candidate,
      score: 0.18,
      reason: "Registered channel #{channel_id}.",
      channel_id: channel_id,
      plugin_id: field(channel, :plugin_id),
      action_name: "list_channels",
      trace_metadata: %{
        provider: field(channel, :provider),
        enabled: field(channel, :enabled),
        identity_count: field(channel, :identity_count),
        credential_status: field(channel, :credential_status)
      }
    })
  rescue
    _exception -> nil
  end

  defp memory_candidates(request) do
    text = field(request, :text) || ""

    []
    |> add_indexed_memory_candidates(request, text)
    |> maybe_add_memory_append_candidate(text)
    |> maybe_add_memory_read_candidate(text)
  end

  defp add_indexed_memory_candidates(candidates, request, text) do
    candidates ++ indexed_memory_candidates(request, text)
  end

  defp indexed_memory_candidates(request, text) when is_binary(text) do
    user_id = field(request, :user_id) || field(request, :operator_id) || "local"
    root = Memory.root()

    with true <- memory_index_enabled?(),
         false <- String.trim(text) == "",
         false <- MemoryIndex.stale?(root),
         {:ok, index} <- MemoryIndex.load(root),
         {:ok, entries} <- MemoryIndex.query(index, text, user_id: user_id, limit: 10) do
      entries
      |> Enum.map(&candidate_from_indexed_memory/1)
      |> Enum.reject(&is_nil/1)
    else
      _skip -> []
    end
  rescue
    _exception -> []
  end

  defp indexed_memory_candidates(_request, _text), do: []

  defp candidate_from_indexed_memory(entry) do
    path = field(entry, :path)
    summary = field(entry, :summary)

    Candidate.new!(%{
      kind: :memory,
      id: "markdown_memory:#{path}",
      label: summary,
      source: :memory,
      status: :candidate,
      score: field(entry, :score, 0.1),
      reason: "Indexed markdown memory matched the request.",
      trace_metadata: %{
        category: field(entry, :category),
        timestamp: field(entry, :timestamp),
        review_status: field(entry, :review_status),
        path: path,
        match_reasons: field(entry, :match_reasons, [])
      }
    })
  rescue
    _exception -> nil
  end

  defp maybe_add_memory_append_candidate(candidates, text) do
    if memory_append_text?(text) do
      [
        Candidate.new!(%{
          kind: :memory,
          id: "markdown_memory:append",
          label: "Append markdown memory",
          source: :memory,
          status: :candidate,
          score: 0.3,
          reason: "Request text matched markdown memory write language.",
          action_name: "append_memory",
          skill_name: "append-memory",
          trace_metadata: %{intent: :append_memory}
        })
        | candidates
      ]
    else
      candidates
    end
  end

  defp maybe_add_memory_read_candidate(candidates, text) do
    if memory_read_text?(text) do
      [
        Candidate.new!(%{
          kind: :memory,
          id: "markdown_memory:read_recent",
          label: "Read recent markdown memory",
          source: :memory,
          status: :candidate,
          score: 0.3,
          reason: "Request text matched markdown memory recall language.",
          action_name: "read_recent_memory",
          skill_name: "read-recent-memory",
          trace_metadata: %{intent: :read_recent_memory}
        })
        | candidates
      ]
    else
      candidates
    end
  end

  defp objective_candidates(_request, nil, _registry), do: []

  defp objective_candidates(request, true, registry) do
    user_id = field(request, :user_id) || field(request, :operator_id) || "local"

    user_id
    |> Objectives.list_objectives(status: ["open", "running", "blocked"], limit: 5)
    |> Enum.map(&candidate_from_objective(&1, registry))
    |> Enum.reject(&is_nil/1)
  rescue
    _exception -> []
  end

  defp objective_candidates(_request, %Objective{} = objective, registry) do
    [candidate_from_objective(objective, registry)]
    |> Enum.reject(&is_nil/1)
  end

  defp objective_candidates(_request, objectives, registry) when is_list(objectives) do
    objectives
    |> Enum.map(&candidate_from_objective(&1, registry))
    |> Enum.reject(&is_nil/1)
  end

  defp objective_candidates(_request, %{} = objective, registry) do
    [candidate_from_objective(objective, registry)]
    |> Enum.reject(&is_nil/1)
  end

  defp objective_candidates(_request, _objective, _registry), do: []

  defp candidate_from_objective(objective, registry) do
    id = field(objective, :id)
    title = field(objective, :title)

    Candidate.new!(
      %{
        kind: :objective,
        id: id,
        label: title,
        source: :objective,
        status: :candidate,
        score: 0.2,
        reason: title || "Active objective #{id}.",
        app_id: app_id_from_string(field(objective, :active_app), registry),
        trace_metadata: %{
          objective_id: id,
          title: title,
          objective: field(objective, :objective),
          status: field(objective, :status),
          source_thread_id: field(objective, :source_thread_id),
          current_step_id: field(objective, :current_step_id),
          loop_count: field(objective, :loop_count)
        }
      },
      registry
    )
  rescue
    _exception -> nil
  end

  defp refusal_candidates(request) do
    text = field(request, :text) || ""

    if refusal_text?(text) do
      [
        Candidate.new!(%{
          kind: :refusal,
          id: "unsupported_resource_workflow",
          label: "Unsupported resource workflow",
          source: :deterministic,
          status: :candidate,
          score: 0.3,
          reason: "Request text matched an unsupported resource workflow.",
          action_name: "unsupported_resource_workflow",
          trace_metadata: %{intent: :unsupported_resource_workflow}
        })
      ]
    else
      []
    end
  end

  defp include_selected(candidates, selected) do
    candidates =
      Enum.reject(candidates, fn candidate ->
        field(candidate, :kind) == selected.kind and field(candidate, :id) == selected.id
      end)

    [selected | candidates]
  end

  defp put_classifier(trace_metadata, nil), do: trace_metadata

  defp put_classifier(trace_metadata, diagnostic),
    do: Map.put(trace_metadata, :classifier, diagnostic)

  defp put_route_hint(trace_metadata, candidate) do
    if get_in_trace(candidate, :engine_route_hint?) == true do
      trace_metadata
      |> Map.put(:engine_route_hint?, true)
      |> Map.put(:engine_route_hint, field(candidate, :trace_metadata, %{}))
    else
      trace_metadata
    end
  end

  defp build_decision(
         attrs,
         %{route_decision: %Decision{} = decision},
         classifier_diagnostic,
         registry
       ) do
    if selected_route_decision_attrs?(attrs) do
      {:ok, put_classifier_on_decision(decision, classifier_diagnostic)}
    else
      Decision.new(attrs, registry)
    end
  end

  defp build_decision(attrs, _request, _classifier_diagnostic, registry),
    do: Decision.new(attrs, registry)

  defp selected_route_decision_attrs?(attrs) do
    attrs[:trace_metadata]
    |> field(:engine_route_hint?, false)
  end

  defp put_classifier_on_decision(%Decision{} = decision, nil), do: decision

  defp put_classifier_on_decision(%Decision{} = decision, diagnostic) do
    %{decision | trace_metadata: Map.put(decision.trace_metadata, :classifier, diagnostic)}
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

  defp active_app_context(request, registry) do
    requested = field(request, :active_app) || field(request, :app_id)
    do_active_app_context(requested, registry)
  end

  defp do_active_app_context(requested, registry) do
    case AppRegistry.normalize_app_id(requested, RegistryContext.app_opts(registry)) do
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

  defp normalized_active_app(request, registry),
    do: active_app_context(request, registry).active_app

  defp route_hint_direct_answer?(request) do
    case field(request, :route_hint) do
      %{route: :direct_answer} -> true
      %{"route" => :direct_answer} -> true
      nil -> true
      _other -> false
    end
  end

  defp explicit_route_hint?(request) do
    request
    |> field(:route_hint, %{})
    |> field(:explicit?, false)
  end

  defp classifier_allowed?(request) do
    route_hint_direct_answer?(request)
  end

  defp rejected_candidates(candidates, selected) do
    if trace_rejected_candidates?() do
      candidates
      |> Enum.reject(&(field(&1, :id) == selected.id and field(&1, :kind) == selected.kind))
      |> Enum.take(12)
      |> Enum.map(&rejected_candidate_to_map/1)
    else
      []
    end
  end

  defp rejected_candidate_to_map(candidate) do
    candidate
    |> Candidate.to_map()
    |> Map.drop([:trace_metadata, :resource_access])
  end

  defp memory_candidate_maps(candidates) do
    candidates
    |> Enum.filter(&(field(&1, :kind) == :memory))
    |> Enum.take(5)
    |> Enum.map(fn candidate ->
      candidate
      |> Candidate.to_map()
      |> Map.take([:kind, :id, :source, :score, :reason, :trace_metadata])
    end)
  end

  defp objective_candidate_maps(candidates) do
    candidates
    |> Enum.filter(&(field(&1, :kind) == :objective))
    |> Enum.take(5)
    |> Enum.map(fn candidate ->
      candidate
      |> Candidate.to_map()
      |> Map.take([:kind, :id, :source, :score, :reason, :trace_metadata])
    end)
  end

  defp descriptor_candidate_maps(candidates) do
    candidates
    |> Enum.filter(&(field(&1, :kind) == :app_intent))
    |> Enum.take(10)
    |> Enum.map(fn candidate ->
      candidate
      |> Candidate.to_map()
      |> Map.take([:kind, :id, :source, :score, :reason, :app_id, :action_name, :trace_metadata])
    end)
  end

  defp objective_opts(%{objective: objective}), do: [objective: objective]
  defp objective_opts(%{"objective" => objective}), do: [objective: objective]
  defp objective_opts(_context), do: []

  # v1.0.2 M2 (ADR 0082): the internal registry context rides the metadata
  # context map (mirroring objective_opts/1) so put_candidate_metadata/2 collects
  # against the same registries the decision was produced with.
  defp registry_opts(%{registry: registry}) when is_list(registry),
    do: RegistryContext.take(registry)

  defp registry_opts(%{"registry" => registry}) when is_list(registry),
    do: RegistryContext.take(registry)

  defp registry_opts(_context), do: []

  defp metadata_context(request, []), do: %{request: request}
  defp metadata_context(request, registry), do: %{request: request, registry: registry}

  defp trace_rejected_candidates? do
    case Settings.get("intent.trace_rejected_candidates") do
      {:ok, false} -> false
      _other -> true
    end
  rescue
    _exception -> true
  end

  defp memory_index_enabled? do
    case Settings.get("memory.index_enabled") do
      {:ok, false} -> false
      _other -> true
    end
  rescue
    _exception -> true
  end

  defp descriptors_enabled? do
    case Settings.get("intent.descriptors_enabled") do
      {:ok, false} -> false
      _other -> true
    end
  rescue
    _exception -> true
  end

  defp handoff_threshold, do: bounded_setting("intent.handoff_threshold", 0.6)
  defp handoff_margin, do: bounded_setting("intent.handoff_margin", 0.15)
  defp clarify_floor, do: bounded_setting("intent.clarify_floor", 0.3)

  defp bounded_setting(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_float(value) -> value |> max(0.0) |> min(1.0)
      {:ok, value} when is_integer(value) -> (value / 1) |> max(0.0) |> min(1.0)
      _other -> default
    end
  rescue
    _exception -> default
  end

  defp neutral_app?(nil), do: true
  defp neutral_app?(:allbert), do: true
  defp neutral_app?(_app_id), do: false

  defp action_resource_access(%Capability{name: name}, request) do
    request
    |> field(:route_decision)
    |> case do
      %Decision{selected_action: ^name, resource_access: entries} -> entries
      _other -> []
    end
  end

  defp app_id_from_string(nil, _registry), do: nil

  defp app_id_from_string(app_id, registry) when is_binary(app_id) do
    case AppRegistry.normalize_app_id(app_id, RegistryContext.app_opts(registry)) do
      {:ok, app_id} -> app_id
      {:error, _reason} -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp app_id_from_string(app_id, _registry) when is_atom(app_id), do: app_id
  defp app_id_from_string(_app_id, _registry), do: nil

  defp memory_append_text?(text) when is_binary(text) do
    normalized = String.downcase(text)

    not sensitive_memory_text?(normalized) and
      (String.contains?(normalized, "remember") ||
         String.contains?(normalized, "my name is") ||
         String.contains?(normalized, "i prefer") ||
         String.contains?(normalized, "save this"))
  end

  defp memory_append_text?(_text), do: false

  defp sensitive_memory_text?(text) do
    Regex.match?(~r/\b(password|passphrase|secret|api[_ -]?key|token|private key)\b/i, text)
  end

  defp memory_read_text?(text) when is_binary(text) do
    normalized = String.downcase(text)

    String.contains?(normalized, "what do you remember") ||
      String.contains?(normalized, "recall") ||
      String.contains?(normalized, "what is my name") ||
      String.contains?(normalized, "remember about")
  end

  defp memory_read_text?(_text), do: false

  defp refusal_text?(text) when is_binary(text) do
    normalized = String.downcase(text)

    String.contains?(normalized, "read local file") ||
      String.contains?(normalized, "crawl ") ||
      String.contains?(normalized, "agent://")
  end

  defp refusal_text?(_text), do: false

  defp job_text?(text) when is_binary(text) do
    text_contains_any?(text, ["job", "jobs", "schedule", "scheduled"])
  end

  defp job_text?(_text), do: false

  defp channel_text?(text) when is_binary(text) do
    text_contains_any?(text, ["channel", "channels", "telegram", "email", "sms"])
  end

  defp channel_text?(_text), do: false

  defp text_contains_any?(text, values) do
    normalized = String.downcase(text)
    Enum.any?(values, &String.contains?(normalized, &1))
  end

  defp skill_candidates_relevant?(request) do
    route =
      request
      |> field(:route_hint, %{})
      |> field(:route)

    is_nil(route) or
      route in [
        :direct_answer,
        :list_skills,
        :read_skill,
        :activate_skill,
        :append_memory,
        :append_personal_memory,
        :read_recent_memory
      ] or
      skill_text?(field(request, :text))
  end

  defp skill_text?(text) when is_binary(text) do
    text_contains_any?(text, ["skill", "skills", "capabilities", "what can you do"])
  end

  defp skill_text?(_text), do: false

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

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
