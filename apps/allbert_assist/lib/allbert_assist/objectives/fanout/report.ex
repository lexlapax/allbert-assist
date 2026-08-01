defmodule AllbertAssist.Objectives.Fanout.Report do
  @moduledoc """
  Pure construction of the immutable fan-in input and selected report body.

  Durable Objectives rows remain the authority. This module only normalizes an
  already-loaded parent and its terminal children into one canonical snapshot,
  hashes that snapshot, and renders either a deterministic fallback or one
  deterministic synthesis selected through a closed, content-free section
  layout. The model may group completed child observations by a bounded
  relationship enum and order them; it cannot arrange failures or author report
  facts, status language, failure language, or effect claims.
  """

  alias AllbertAssist.Objectives.AcceptanceCriteria
  alias AllbertAssist.Objectives.Fanout.PlanProvenance
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Runtime.Redactor

  @version 1
  @layout_version 1
  @digest_domain "allbert:fanout-report-input:v1\0"
  @selection_digest_domain "allbert:fanout-report-selection:v1\0"
  @terminal ~w[completed cancelled failed abandoned]
  @detail_bytes 500
  @rendered_objective_bytes 500
  @report_bytes 32_768
  @appendix_heading "Authoritative child results (ordered):"
  @relationships ~w[complementary contrasting sequential supporting independent]
  @relational_relationships ~w[complementary contrasting sequential supporting]
  @fallback_reasons ~w[
    model_disabled budget_denied invalid_budget_snapshot deadline_exhausted
    profile_unavailable transport_denied provider_failed invalid_model_output
    recovery_after_restart historical_backfill
  ]

  @type evidence_ref :: %{
          kind: String.t(),
          action: String.t(),
          trace_id: String.t()
        }

  @type child_envelope :: %{
          id: String.t(),
          queue_position: non_neg_integer(),
          title: String.t(),
          objective: String.t(),
          expected_result: String.t() | nil,
          status: String.t(),
          detail: String.t(),
          effect_receipt_ref: evidence_ref() | nil
        }

  @type snapshot :: %{
          version: pos_integer(),
          parent_id: String.t(),
          title: String.t(),
          original_request: String.t(),
          status: String.t(),
          join_outcome: String.t(),
          plan: map(),
          children: [child_envelope()]
        }

  @type frozen :: %{
          snapshot: snapshot(),
          input_digest: String.t(),
          fallback_body: String.t()
        }

  @type composition_section :: %{
          relationship: String.t(),
          ordered_queue_positions: [non_neg_integer()]
        }

  @type composition_layout :: %{
          layout_version: pos_integer(),
          sections: [composition_section()]
        }

  @doc "Build one canonical, redacted input from an already-frozen durable row set."
  @spec freeze(Objective.t(), [Objective.t()], %{optional(String.t()) => evidence_ref()}) ::
          {:ok, frozen()} | {:error, term()}
  def freeze(parent, children, effect_evidence_refs \\ %{})

  def freeze(%Objective{} = parent, children, effect_evidence_refs)
      when is_list(children) and is_map(effect_evidence_refs) do
    ordered = Enum.sort_by(children, &{&1.queue_position, &1.id})

    with :ok <- validate_parent(parent),
         :ok <- validate_children(ordered),
         {:ok, envelopes} <- child_envelopes(ordered, effect_evidence_refs) do
      safe_plan = plan_provenance(parent.proposer_hint)

      snapshot =
        Redactor.redact(%{
          version: @version,
          parent_id: parent.id,
          title: bounded_text(parent.title, 200),
          original_request: bounded_text(parent.objective, 4_000),
          status: parent.status,
          join_outcome: parent.join_outcome,
          plan: %{},
          children: envelopes
        })
        |> Map.put(:plan, safe_plan)

      {:ok,
       %{
         snapshot: snapshot,
         input_digest: digest(snapshot),
         fallback_body: fallback(snapshot)
       }}
    end
  end

  def freeze(_parent, _children, _effect_evidence_refs),
    do: {:error, :invalid_fanout_report_input}

  @doc "Return the lowercase SHA-256 binding for one canonical snapshot."
  @spec digest(snapshot()) :: String.t()
  def digest(snapshot) when is_map(snapshot) do
    :sha256
    |> :crypto.hash([@digest_domain, canonical_json(snapshot)])
    |> Base.encode16(case: :lower)
  end

  @doc "Render the deterministic complete-child report used for fallback."
  @spec fallback(snapshot()) :: String.t()
  def fallback(snapshot) when is_map(snapshot) do
    heading =
      "#{snapshot.title} — #{snapshot.join_outcome || snapshot.status}"

    bounded_report(heading <> "\n\n" <> authoritative_appendix(snapshot.children))
  end

  @doc "Render a factual report from one closed, complete child-layout selection."
  @spec compose(snapshot(), map()) :: {:ok, String.t()} | {:error, term()}
  def compose(snapshot, selection) do
    with {:ok, prepared} <- prepare_composition(snapshot, selection) do
      {:ok, prepared.body}
    end
  end

  @doc "Validate and version one model section layout before durable selection."
  @spec prepare_composition(snapshot(), map()) ::
          {:ok, %{body: String.t(), layout: composition_layout()}} | {:error, term()}
  def prepare_composition(%{children: children} = snapshot, selection)
      when is_list(children) and is_map(selection) do
    with {:ok, sections} <- normalize_model_selection(selection),
         layout <- %{layout_version: @layout_version, sections: sections},
         {:ok, body} <- render_composition(snapshot, layout) do
      {:ok, %{body: body, layout: layout}}
    end
  end

  def prepare_composition(_snapshot, _selection),
    do: {:error, :invalid_fanout_report_selection}

  @doc "Render one already-versioned durable layout through its exact contract version."
  @spec render_composition(snapshot(), map()) :: {:ok, String.t()} | {:error, term()}
  def render_composition(%{children: children} = snapshot, layout)
      when is_list(children) and is_map(layout) do
    with {:ok, normalized} <- normalize_persisted_layout(layout),
         :ok <- validate_completed_partition(children, normalized.sections),
         {:ok, rendered_sections} <- select_sections(children, normalized.sections) do
      body =
        deterministic_synthesis(snapshot, rendered_sections) <>
          "\n\n" <> authoritative_appendix(children)

      cond do
        body != Redactor.redact(body) -> {:error, :unredacted_fanout_report}
        byte_size(body) > @report_bytes -> {:error, :fanout_report_too_large}
        true -> {:ok, body}
      end
    end
  end

  def render_composition(_snapshot, _layout),
    do: {:error, :invalid_fanout_report_layout}

  @doc "Validate that a selected body preserves the exact authoritative appendix."
  @spec validate_selected_body(snapshot(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def validate_selected_body(snapshot, "deterministic_fallback", body, provenance)
      when is_map(snapshot) and is_binary(body) and is_map(provenance) do
    with {:ok, _normalized} <-
           normalize_selection_provenance("deterministic_fallback", provenance) do
      cond do
        body != Redactor.redact(body) -> {:error, :unredacted_fanout_report}
        body != fallback(snapshot) -> {:error, :invalid_deterministic_fanout_report}
        true -> :ok
      end
    end
  end

  def validate_selected_body(snapshot, "model", body, provenance)
      when is_map(snapshot) and is_binary(body) and is_map(provenance) do
    with {:ok, normalized} <- normalize_selection_provenance("model", provenance),
         layout <- %{
           layout_version: normalized.layout_version,
           sections: normalized.sections
         },
         {:ok, expected_body} <- render_composition(snapshot, layout),
         true <- body == expected_body do
      :ok
    else
      false -> {:error, :invalid_model_fanout_report}
      {:error, _reason} = error -> error
    end
  end

  def validate_selected_body(_snapshot, _source, _body, _provenance),
    do: {:error, :invalid_fanout_report_selection}

  @doc "Normalize the only content-free provenance allowed on a selected report event."
  @spec normalize_selection_provenance(String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def normalize_selection_provenance("model", provenance) when is_map(provenance) do
    with true <-
           map_size(provenance) == 5 and
             provenance_keys(provenance) ==
               ~w[layout_version model model_profile provider sections],
         {:ok, profile} <-
           provenance_identifier(provenance_field(provenance, :model_profile), 120),
         {:ok, provider} <- provenance_identifier(provenance_field(provenance, :provider), 120),
         {:ok, model} <- provenance_identifier(provenance_field(provenance, :model), 240),
         {:ok, layout} <-
           normalize_persisted_layout(%{
             layout_version: provenance_field(provenance, :layout_version),
             sections: provenance_field(provenance, :sections)
           }) do
      {:ok,
       %{
         model_profile: profile,
         provider: provider,
         model: model,
         layout_version: layout.layout_version,
         sections: layout.sections
       }}
    else
      _invalid -> {:error, :invalid_fanout_report_provenance}
    end
  end

  def normalize_selection_provenance("deterministic_fallback", provenance)
      when is_map(provenance) do
    reason = provenance_field(provenance, :fallback_reason)
    normalized_reason = if is_atom(reason), do: Atom.to_string(reason), else: reason

    version = provenance_field(provenance, :layout_version) || @layout_version
    keys = provenance_keys(provenance)

    cond do
      keys not in [["fallback_reason"], ~w[fallback_reason layout_version]] ->
        {:error, :invalid_fanout_report_provenance}

      map_size(provenance) != length(keys) ->
        {:error, :invalid_fanout_report_provenance}

      normalized_reason not in @fallback_reasons ->
        {:error, :invalid_fanout_report_provenance}

      version != @layout_version ->
        {:error, :unsupported_fanout_report_layout_version}

      true ->
        {:ok, %{fallback_reason: normalized_reason, layout_version: @layout_version}}
    end
  end

  def normalize_selection_provenance(_source, _provenance),
    do: {:error, :invalid_fanout_report_provenance}

  @doc "Bind the selected source and every normalized provenance field."
  @spec selection_digest(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def selection_digest(source, provenance) when is_binary(source) and is_map(provenance) do
    with {:ok, normalized} <- normalize_selection_provenance(source, provenance) do
      digest =
        :sha256
        |> :crypto.hash([
          @selection_digest_domain,
          canonical_json(%{source: source, provenance: normalized})
        ])
        |> Base.encode16(case: :lower)

      {:ok, digest}
    end
  end

  def selection_digest(_source, _provenance),
    do: {:error, :invalid_fanout_report_provenance}

  @doc "Validate a reconstructed snapshot against its durable binding."
  @spec verify(frozen(), String.t()) :: :ok | {:error, :fanout_report_input_mismatch}
  def verify(%{input_digest: digest}, digest) when is_binary(digest), do: :ok
  def verify(%{input_digest: _actual}, _expected), do: {:error, :fanout_report_input_mismatch}

  defp validate_parent(%Objective{
         id: id,
         fanout_role: "parent",
         status: status,
         join_outcome: outcome
       })
       when is_binary(id) and status in @terminal and
              outcome in ~w[success partial failed cancelled],
       do: :ok

  defp validate_parent(_parent), do: {:error, :invalid_fanout_report_parent}

  defp provenance_keys(provenance) do
    provenance
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp provenance_field(provenance, key),
    do: Map.get(provenance, key) || Map.get(provenance, Atom.to_string(key))

  defp provenance_identifier(value, max_bytes) when is_binary(value) do
    if value != "" and value == String.trim(value) and byte_size(value) <= max_bytes and
         value == Redactor.redact(value) do
      {:ok, value}
    else
      {:error, :invalid_fanout_report_provenance}
    end
  end

  defp provenance_identifier(_value, _max_bytes),
    do: {:error, :invalid_fanout_report_provenance}

  defp validate_children([]), do: {:error, :fanout_report_children_required}

  defp validate_children(children) do
    cond do
      Enum.any?(children, &(&1.fanout_role != "child")) ->
        {:error, :invalid_fanout_report_child}

      Enum.any?(children, &(&1.status not in @terminal)) ->
        {:error, :fanout_report_children_not_terminal}

      Enum.any?(children, &(not is_integer(&1.queue_position) or &1.queue_position < 0)) ->
        {:error, :invalid_fanout_report_child_position}

      children |> Enum.map(& &1.queue_position) |> Enum.uniq() |> length() != length(children) ->
        {:error, :duplicate_fanout_report_child_position}

      true ->
        :ok
    end
  end

  defp normalize_model_selection(selection) do
    if map_size(selection) == 1 and provenance_keys(selection) == ["sections"] do
      normalize_sections(provenance_field(selection, :sections))
    else
      {:error, :invalid_fanout_report_composition_selection}
    end
  end

  defp normalize_persisted_layout(layout) do
    with true <-
           map_size(layout) == 2 and
             provenance_keys(layout) == ~w[layout_version sections],
         @layout_version <- provenance_field(layout, :layout_version),
         {:ok, sections} <- normalize_sections(provenance_field(layout, :sections)) do
      {:ok, %{layout_version: @layout_version, sections: sections}}
    else
      version when is_integer(version) -> {:error, :unsupported_fanout_report_layout_version}
      _invalid -> {:error, :invalid_fanout_report_composition_selection}
    end
  end

  defp normalize_sections(sections) when is_list(sections) do
    sections
    |> Enum.reduce_while({:ok, []}, fn section, {:ok, normalized} ->
      case normalize_section(section) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_sections(_sections),
    do: {:error, :invalid_fanout_report_composition_sections}

  defp normalize_section(section) when is_map(section) do
    with true <-
           map_size(section) == 2 and
             provenance_keys(section) == ~w[ordered_queue_positions relationship],
         relationship when relationship in @relationships <-
           provenance_field(section, :relationship),
         positions when is_list(positions) and positions != [] <-
           provenance_field(section, :ordered_queue_positions),
         true <- Enum.all?(positions, &(is_integer(&1) and &1 >= 0)),
         true <- length(Enum.uniq(positions)) == length(positions),
         :ok <- validate_relationship_cardinality(relationship, positions) do
      {:ok, %{relationship: relationship, ordered_queue_positions: positions}}
    else
      _invalid -> {:error, :invalid_fanout_report_composition_section}
    end
  end

  defp normalize_section(_section),
    do: {:error, :invalid_fanout_report_composition_section}

  defp validate_relationship_cardinality("independent", [_position]), do: :ok

  defp validate_relationship_cardinality(relationship, positions)
       when relationship in @relational_relationships and length(positions) >= 2,
       do: :ok

  defp validate_relationship_cardinality(_relationship, _positions),
    do: {:error, :invalid_fanout_report_relationship_cardinality}

  defp validate_completed_partition(children, sections) do
    expected =
      children
      |> Enum.filter(&(map_field(&1, :status) == "completed"))
      |> Enum.map(&map_field(&1, :queue_position))
      |> Enum.sort()

    selected =
      sections
      |> Enum.flat_map(& &1.ordered_queue_positions)

    cond do
      length(Enum.uniq(selected)) != length(selected) ->
        {:error, :duplicate_fanout_report_composition_position}

      Enum.sort(selected) != expected ->
        {:error, :incomplete_fanout_report_composition_selection}

      length(expected) >= 2 and
          not Enum.any?(sections, fn section ->
            section.relationship != "independent" and
                length(section.ordered_queue_positions) >= 2
          end) ->
        {:error, :fanout_report_relationship_section_required}

      true ->
        :ok
    end
  end

  defp select_sections(children, sections) do
    completed_by_position =
      children
      |> Enum.filter(&(map_field(&1, :status) == "completed"))
      |> Map.new(&{map_field(&1, :queue_position), &1})

    sections
    |> Enum.reduce_while({:ok, []}, fn section, {:ok, rendered} ->
      case select_section_children(completed_by_position, section.ordered_queue_positions) do
        {:ok, selected} ->
          {:cont, {:ok, [%{relationship: section.relationship, children: selected} | rendered]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      {:error, _reason} = error -> error
    end
  end

  defp select_section_children(children_by_position, positions) do
    positions
    |> Enum.reduce_while({:ok, []}, fn position, {:ok, selected} ->
      case Map.fetch(children_by_position, position) do
        {:ok, child} -> {:cont, {:ok, [child | selected]}}
        :error -> {:halt, {:error, :unknown_fanout_report_composition_position}}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      {:error, _reason} = error -> error
    end
  end

  defp deterministic_synthesis(snapshot, rendered_sections) do
    children = map_field(snapshot, :children)
    attention = Enum.reject(children, &(map_field(&1, :status) == "completed"))

    [
      "#{map_field(snapshot, :title)} — #{map_field(snapshot, :join_outcome) || map_field(snapshot, :status)}",
      status_totals(children),
      attention_section(attention),
      relationship_sections(rendered_sections),
      "Effect verification comes only from the authoritative child-results appendix below."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp status_totals(children) do
    counts = Enum.frequencies_by(children, &map_field(&1, :status))

    "Child status totals: completed=#{Map.get(counts, "completed", 0)}; " <>
      "failed=#{Map.get(counts, "failed", 0)}; " <>
      "cancelled=#{Map.get(counts, "cancelled", 0)}; " <>
      "abandoned=#{Map.get(counts, "abandoned", 0)}."
  end

  defp attention_section([]), do: nil

  defp attention_section(children) do
    "Attention required (not model-arranged):\n" <>
      Enum.map_join(children, "\n", &synthesis_line/1)
  end

  defp relationship_sections([]),
    do: "Completed synthesis:\nNo completed child result was recorded."

  defp relationship_sections(sections) do
    "Completed synthesis:\n\n" <> Enum.map_join(sections, "\n\n", &relationship_section/1)
  end

  defp relationship_section(%{relationship: relationship, children: children}) do
    relationship_heading(relationship) <>
      "\nSelected relationship: #{relationship}.\n" <>
      relationship_intro(relationship, children) <>
      "\n" <> Enum.map_join(children, "\n", &synthesis_line/1)
  end

  defp relationship_heading("complementary"), do: "Complementary findings:"
  defp relationship_heading("contrasting"), do: "Contrasting findings:"
  defp relationship_heading("sequential"), do: "Sequential findings:"
  defp relationship_heading("supporting"), do: "Supporting findings:"
  defp relationship_heading("independent"), do: "Independent finding:"

  defp relationship_intro("complementary", children),
    do:
      "This section relates #{joined_member_refs(children)} as complementary parts of the request."

  defp relationship_intro("contrasting", children),
    do: "This section contrasts #{joined_member_refs(children)}."

  defp relationship_intro("sequential", children),
    do: "This section orders #{sequence_member_refs(children)} as a sequence."

  defp relationship_intro("supporting", children),
    do:
      "This section relates #{joined_member_refs(children)} as mutually supporting parts of the request."

  defp relationship_intro("independent", children),
    do:
      "This section presents #{joined_member_refs(children)} independently within the joined answer."

  defp joined_member_refs(children) do
    children
    |> Enum.map(&member_ref/1)
    |> case do
      [only] -> only
      [first, second] -> first <> " and " <> second
      many -> Enum.join(Enum.drop(many, -1), ", ") <> ", and " <> List.last(many)
    end
  end

  defp sequence_member_refs(children),
    do: children |> Enum.map(&member_ref/1) |> Enum.join(" then ")

  defp member_ref(child) do
    title = child |> map_field(:title) |> inline_bounded_text(200)
    objective = child |> map_field(:objective) |> inline_bounded_text(@rendered_objective_bytes)
    Jason.encode!(title) <> " (objective: " <> Jason.encode!(objective) <> ")"
  end

  defp synthesis_line(child) do
    position = map_field(child, :queue_position)
    title = map_field(child, :title)
    objective = bounded_text(map_field(child, :objective), @rendered_objective_bytes)

    "- Child #{position + 1}: #{title} [#{map_field(child, :status)}]\n" <>
      "  Objective: #{objective}\n" <>
      "  #{observation_label(child)}: #{map_field(child, :detail)}"
  end

  defp observation_label(%{effect_receipt_ref: nil}),
    do: "Child-reported observation (not effect evidence)"

  defp observation_label(_child), do: "Child-reported observation"

  defp inline_bounded_text(value, limit) do
    value
    |> bounded_text(limit)
    |> String.split()
    |> Enum.join(" ")
  end

  defp child_envelopes(children, effect_evidence_refs) do
    {:ok,
     Enum.map(children, fn child ->
       %{
         id: child.id,
         queue_position: child.queue_position,
         title: bounded_text(child.title, 200),
         objective: bounded_text(child.objective, 4_000),
         expected_result: expected_result(child.acceptance_criteria),
         status: child.status,
         detail: terminal_detail(child),
         effect_receipt_ref: evidence_ref(effect_evidence_refs, child.id)
       }
     end)}
  end

  defp evidence_ref(refs, child_id) do
    case Map.get(refs, child_id) do
      %{kind: kind, action: action, trace_id: trace_id}
      when is_binary(kind) and is_binary(action) and is_binary(trace_id) ->
        %{
          kind: bounded_text(kind, 40),
          action: bounded_text(action, 240),
          trace_id: bounded_text(trace_id, 128)
        }

      _other ->
        nil
    end
  end

  defp expected_result(criteria) do
    case AcceptanceCriteria.decode(criteria) do
      {:ok, %{"summary" => summary}} when is_binary(summary) -> bounded_text(summary, 500)
      _other -> nil
    end
  end

  defp terminal_detail(%Objective{status: "completed"} = child) do
    bounded_detail(
      child.last_observation_summary || child.progress_summary,
      "No result summary recorded."
    )
  end

  defp terminal_detail(%Objective{} = child) do
    bounded_detail(
      child.review_reason || child.last_observation_summary || child.progress_summary,
      "No terminal reason recorded."
    )
  end

  defp bounded_detail(nil, fallback), do: fallback

  defp bounded_detail(value, fallback) do
    case value |> Redactor.redact() |> to_string() |> String.trim() do
      "" -> fallback
      text -> bounded_text(text, @detail_bytes)
    end
  end

  defp authoritative_appendix(children) do
    lines =
      Enum.map_join(children, "\n", fn child ->
        "- #{glyph(child.status)} #{child.title} [#{child.status}] — " <>
          "#{observation_label(child)}: #{child.detail}\n" <>
          "  Effect receipt: #{effect_receipt(child.effect_receipt_ref)}"
      end)

    @appendix_heading <> "\n" <> lines
  end

  defp effect_receipt(nil),
    do: "none recorded. Child-reported observation is not effect evidence."

  defp effect_receipt(%{kind: kind, action: action, trace_id: trace_id}) do
    "kind=#{Jason.encode!(kind)}; action=#{Jason.encode!(action)}; " <>
      "trace_id=#{Jason.encode!(trace_id)}"
  end

  defp glyph("completed"), do: "✓"
  defp glyph("cancelled"), do: "⊘"
  defp glyph("failed"), do: "✗"
  defp glyph("abandoned"), do: "✗"

  defp plan_provenance(value) do
    case PlanProvenance.decode_parent_hint(value) do
      {:ok, plan} -> plan
      {:error, _reason} -> %{}
    end
  end

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp map_field(map, key) when is_map(map), do: Map.get(map, key)
  defp map_field(_value, _key), do: nil

  defp bounded_text(nil, _limit), do: ""

  defp bounded_text(value, limit) do
    value
    |> Redactor.redact()
    |> to_string()
    |> truncate_utf8(limit)
  end

  defp bounded_report(report), do: truncate_utf8(report, @report_bytes)

  defp truncate_utf8(value, limit) when byte_size(value) <= limit, do: value

  defp truncate_utf8(value, limit) do
    value
    |> binary_part(0, limit)
    |> trim_invalid_utf8()
  end

  defp trim_invalid_utf8(value) do
    if String.valid?(value),
      do: value,
      else: value |> binary_part(0, byte_size(value) - 1) |> trim_invalid_utf8()
  end

  defp canonical_json(value), do: encode_json(stringify_keys(value))

  defp encode_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> encode_json(value) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp encode_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &encode_json/1) <> "]"

  defp encode_json(value), do: Jason.encode!(value)
end
