defmodule AllbertAssist.SelfImprovement.Discovery do
  @moduledoc """
  Read-only self-improvement pattern discovery service.

  This service reads trace-index patterns, objective-event context, and reviewed
  memory counts, then writes only inert advisory suggestion rows through the
  existing discovery suggestion surface.
  """

  alias AllbertAssist.Maps
  alias AllbertAssist.Memory
  alias AllbertAssist.Objectives
  alias AllbertAssist.SelfImprovement.TraceIndex
  alias AllbertAssist.Tools.Discovery, as: Suggestions
  alias AllbertAssist.Validation

  @default_limit 8
  @max_limit 25

  @type discovery_result :: %{
          required(:suggestions) => [map()],
          required(:diagnostics) => nonempty_list(map()),
          required(:sources) => %{
            required(:trace_patterns) => non_neg_integer(),
            required(:memory_review) => map(),
            required(:objective_events) => non_neg_integer()
          }
        }

  @spec discover(map(), map()) :: {:ok, discovery_result()}
  def discover(params \\ %{}, context \\ %{}) when is_map(params) and is_map(context) do
    query = query(params)
    filters = filters(params, context)

    {:ok, trace_index} =
      filters
      |> Map.put(:limit, limit(params))
      |> TraceIndex.index()

    patterns = filter_patterns_for_bias(trace_index.patterns, query)

    {suggestions, suggestion_diagnostics} =
      patterns
      |> Enum.map(&persist_suggestion(&1, query, context))
      |> split_results()

    memory_diagnostics = memory_review_diagnostics(filters)
    objective_diagnostics = objective_event_diagnostics(filters)

    {:ok,
     %{
       suggestions: Enum.map(suggestions, &Suggestions.suggestion_to_map/1),
       diagnostics:
         trace_index.diagnostics ++
           suggestion_diagnostics ++ memory_diagnostics ++ objective_diagnostics,
       sources: %{
         trace_patterns: length(patterns),
         memory_review: diagnostic_counts(memory_diagnostics),
         objective_events: diagnostic_count(objective_diagnostics, :objective_events)
       }
     }}
  end

  defp persist_suggestion(pattern, query, context) do
    pattern
    |> suggestion_attrs(query, context)
    |> Suggestions.upsert_self_improvement_suggestion()
    |> case do
      {:ok, suggestion} ->
        {:suggestion, suggestion}

      {:error, reason} ->
        {:diagnostic,
         %{
           source: :self_improvement_suggestions,
           status: :skipped,
           reason: inspect(reason),
           pattern_type: pattern.pattern_type,
           fingerprint: pattern.fingerprint
         }}
    end
  end

  defp split_results(results) do
    Enum.reduce(results, {[], []}, fn
      {:suggestion, suggestion}, {suggestions, diagnostics} ->
        {[suggestion | suggestions], diagnostics}

      {:diagnostic, diagnostic}, {suggestions, diagnostics} ->
        {suggestions, [diagnostic | diagnostics]}
    end)
    |> then(fn {suggestions, diagnostics} ->
      {Enum.reverse(suggestions), Enum.reverse(diagnostics)}
    end)
  end

  defp suggestion_attrs(pattern, query, context) do
    {suggestion_type, draft_kind} = suggestion_type(pattern)

    %{
      suggestion_type: suggestion_type,
      summary: summary(pattern, draft_kind),
      proposed_draft_kind: draft_kind,
      evidence_refs: evidence_refs(pattern),
      provenance: %{
        source: "trace_index",
        pattern_type: pattern.pattern_type,
        fingerprint: pattern.fingerprint,
        count: pattern.count,
        query: query,
        actor: context_field(context, :actor),
        user_id: context_field(context, :user_id),
        app_id: context_field(context, :active_app)
      }
    }
  end

  defp suggestion_type(%{pattern_type: :action_chain}), do: {"trace_to_workflow", "workflow"}
  defp suggestion_type(%{pattern_type: :repeated_prompt}), do: {"trace_to_skill", "skill"}
  defp suggestion_type(%{pattern_type: :correction}), do: {"memory_update", "memory_update"}
  defp suggestion_type(%{pattern_type: :failed_intent}), do: {"memory_update", "memory_update"}
  defp suggestion_type(_pattern), do: {"trace_to_skill", "skill"}

  defp summary(pattern, draft_kind) do
    "#{pattern.summary}; consider a #{draft_kind} draft."
  end

  defp evidence_refs(pattern) do
    [
      %{
        source: "trace_index",
        pattern_type: pattern.pattern_type,
        fingerprint: pattern.fingerprint,
        count: pattern.count,
        source_refs: Map.get(pattern, :source_refs, [])
      }
    ]
  end

  defp filter_patterns_for_bias(patterns, query) do
    case query_bias(query) do
      :skill ->
        Enum.filter(patterns, &(&1.pattern_type in [:repeated_prompt, :correction]))

      :workflow ->
        Enum.filter(patterns, &(&1.pattern_type == :action_chain))

      :any ->
        patterns
    end
  end

  defp query_bias(query) do
    normalized = String.downcase(query)

    cond do
      String.contains?(normalized, "skill") -> :skill
      String.contains?(normalized, "workflow") -> :workflow
      true -> :any
    end
  end

  defp memory_review_diagnostics(filters) do
    user_id = Map.get(filters, :user_id)

    [:kept, :flagged]
    |> Enum.map(fn status ->
      opts =
        [review_status: status, limit: 25]
        |> maybe_put(:user_id, user_id)

      {:ok, entries} = Memory.list_entries(opts)

      %{
        source: :memory_review,
        status: :observed,
        review_status: status,
        count: length(entries)
      }
    end)
  rescue
    exception ->
      [%{source: :memory_review, status: :skipped, reason: Exception.message(exception)}]
  end

  defp objective_event_diagnostics(filters) do
    opts =
      [limit: 25]
      |> put_keyword(:user_id, Map.get(filters, :user_id))
      |> put_keyword(:active_app, Map.get(filters, :app_id))

    events = Objectives.list_events(opts)

    [
      %{
        source: :objective_events,
        status: :observed,
        count: length(events)
      }
    ]
  rescue
    exception ->
      [%{source: :objective_events, status: :skipped, reason: Exception.message(exception)}]
  end

  defp diagnostic_counts(diagnostics) do
    diagnostics
    |> Enum.filter(&(&1.source == :memory_review and &1.status == :observed))
    |> Map.new(&{&1.review_status, &1.count})
  end

  defp diagnostic_count(diagnostics, source) do
    diagnostics
    |> Enum.find(&(&1.source == source and &1.status == :observed))
    |> case do
      nil -> 0
      diagnostic -> diagnostic.count
    end
  end

  defp filters(params, context) do
    %{}
    |> maybe_put(:user_id, field(params, :user_id) || context_field(context, :user_id))
    |> maybe_put(:app_id, field(params, :app_id) || context_field(context, :active_app))
  end

  defp query(params), do: params |> field(:query, field(params, :need, "")) |> to_string()

  defp limit(params) do
    params
    |> field(:limit)
    |> Validation.clamp_limit(@default_limit, @max_limit)
  end

  defp maybe_put(map_or_list, _key, nil), do: map_or_list
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp maybe_put(list, key, value) when is_list(list), do: Keyword.put(list, key, value)

  defp put_keyword(list, _key, nil), do: list
  defp put_keyword(list, key, value), do: Keyword.put(list, key, value)

  defp context_field(context, key), do: field(context, key)

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
