defmodule AllbertAssist.Objectives.Fanout.Report do
  @moduledoc """
  Pure construction of the immutable fan-in input and selected report body.

  Durable Objectives rows remain the authority. This module only normalizes an
  already-loaded parent and its terminal children into one canonical snapshot,
  hashes that snapshot, and renders either a deterministic fallback or one
  deterministic selection. Frozen layout-v1 reports retain their byte-exact,
  content-free section-layout compatibility path. Layout v2 may add one bounded,
  reviewed advisory paragraph, while Allbert still owns every status, failure,
  authority, receipt, delimiter, appendix, byte bound, and digest. Model output
  cannot arrange failures or become action, permission, delivery, or effect
  evidence.
  """

  alias AllbertAssist.Objectives.AcceptanceCriteria
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.PlanProvenance
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Runtime.Redactor

  @version 1
  @layout_version 1
  @v2_version 2
  @digest_domain "allbert:fanout-report-input:v1\0"
  @v2_digest_domain "allbert:fanout-report-input:v2\0"
  @selection_digest_domain "allbert:fanout-report-selection:v1\0"
  @v2_selection_digest_domain "allbert:fanout-report-selection:v2\0"
  @terminal ~w[completed cancelled failed abandoned]
  @max_children 16
  @rendered_title_bytes 80
  @rendered_objective_bytes 160
  @report_bytes 32_768
  @composition_input_bytes 16_384
  @composition_title_bytes 64
  @composition_request_bytes 1_024
  @composition_child_title_bytes 64
  @composition_child_objective_bytes 128
  @composition_detail_bytes 128
  @synthesis_shortening_marker "… [shortened for synthesis input]"
  @synthesis_bytes 4_096
  @appendix_heading "Authoritative child results (ordered):"
  @relationships ~w[complementary contrasting sequential supporting independent]
  @relational_relationships ~w[complementary contrasting sequential supporting]
  @result_authorities ~w[reviewed_advisory registered_action legacy_unreviewed_advisory]
  @sha256_pattern ~r/^[0-9a-f]{64}$/
  @v1_fallback_reasons ~w[
    model_disabled budget_denied invalid_budget_snapshot deadline_exhausted
    profile_unavailable transport_denied provider_failed invalid_model_output
    recovery_after_restart historical_backfill
  ]
  @v2_fallback_reasons @v1_fallback_reasons ++
                         ~w[legacy_unreviewed_children composition_input_too_large no_completed_children synthesis_timeout]
  @unresolved_fallback_reasons ~w[
    provider_failed invalid_model_output recovery_after_restart synthesis_timeout
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
          effect_receipt_ref: evidence_ref() | nil,
          result_authority: String.t() | nil,
          quality_receipt_sha256: String.t() | nil
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

    with :ok <- validate_structure(parent, ordered),
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

  @doc "Build the receipt-bearing layout-v2 input used for every new durable selection."
  @spec freeze_v2(
          Objective.t(),
          [Objective.t()],
          %{optional(String.t()) => evidence_ref()},
          %{optional(String.t()) => map()}
        ) :: {:ok, frozen()} | {:error, term()}
  def freeze_v2(parent, children, effect_evidence_refs \\ %{}, child_authorities \\ %{})

  def freeze_v2(%Objective{} = parent, children, effect_evidence_refs, child_authorities)
      when is_list(children) and is_map(effect_evidence_refs) and is_map(child_authorities) do
    ordered = Enum.sort_by(children, &{&1.queue_position, &1.id})

    with :ok <- validate_structure(parent, ordered),
         {:ok, envelopes} <- v2_child_envelopes(ordered, effect_evidence_refs),
         {:ok, envelopes} <- bind_child_authorities(envelopes, child_authorities) do
      safe_plan = plan_provenance(parent.proposer_hint)

      snapshot =
        Redactor.redact(%{
          version: @v2_version,
          parent_id: parent.id,
          title: bounded_characters(parent.title, 200),
          original_request: bounded_characters(parent.objective, 4_000),
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

  def freeze_v2(_parent, _children, _effect_evidence_refs, _child_authorities),
    do: {:error, :invalid_fanout_report_input}

  @doc false
  @spec validate_structure(Objective.t(), [Objective.t()]) :: :ok | {:error, term()}
  def validate_structure(%Objective{} = parent, children) when is_list(children) do
    ordered = Enum.sort_by(children, &{&1.queue_position, &1.id})

    with :ok <- validate_parent(parent),
         :ok <- validate_children(ordered) do
      :ok
    end
  end

  def validate_structure(_parent, _children), do: {:error, :invalid_fanout_report_input}

  @doc "Return the lowercase SHA-256 binding for one canonical snapshot."
  @spec digest(snapshot()) :: String.t()
  def digest(snapshot) when is_map(snapshot) do
    domain =
      case map_field(snapshot, :version) do
        @v2_version -> @v2_digest_domain
        _v1_or_legacy -> @digest_domain
      end

    :sha256
    |> :crypto.hash([domain, CanonicalJSON.encode(snapshot)])
    |> Base.encode16(case: :lower)
  end

  @doc "Project a bounded, content-only advisory view for model layout selection."
  @spec composition_input(snapshot()) :: {:ok, map()} | {:error, term()}
  def composition_input(%{version: @v2_version, children: children} = snapshot)
      when is_list(children) do
    v2_composition_input(snapshot, children)
  end

  def composition_input(%{children: children} = snapshot) when is_list(children) do
    projection = %{
      title: advisory_text(map_field(snapshot, :title), @composition_title_bytes),
      original_request:
        advisory_text(
          map_field(snapshot, :original_request),
          @composition_request_bytes
        ),
      status: map_field(snapshot, :status),
      join_outcome: map_field(snapshot, :join_outcome),
      children: Enum.map(children, &composition_child/1)
    }

    case Jason.encode(projection) do
      {:ok, encoded} when byte_size(encoded) <= @composition_input_bytes ->
        {:ok, projection}

      _invalid_or_too_large ->
        {:error, :fanout_composition_input_too_large}
    end
  end

  def composition_input(_snapshot), do: {:error, :invalid_fanout_report_input}

  @doc "Return whether a frozen input may cross the layout-v2 synthesis boundary."
  @spec synthesis_eligibility(snapshot()) :: :ok | {:error, term()}
  def synthesis_eligibility(%{version: @v2_version, children: children})
      when is_list(children) do
    completed = Enum.filter(children, &(map_field(&1, :status) == "completed"))

    cond do
      completed == [] ->
        {:error, :no_completed_children}

      Enum.any?(completed, fn child ->
        map_field(child, :result_authority) == "legacy_unreviewed_advisory"
      end) ->
        {:error, :legacy_unreviewed_children}

      Enum.all?(completed, &valid_synthesis_child_authority?/1) ->
        :ok

      true ->
        {:error, :invalid_fanout_report_child_authority}
    end
  end

  def synthesis_eligibility(%{version: @version}),
    do: {:error, :legacy_unreviewed_children}

  def synthesis_eligibility(_snapshot),
    do: {:error, :invalid_fanout_report_input}

  defp valid_synthesis_child_authority?(child) do
    case map_field(child, :result_authority) do
      "reviewed_advisory" -> sha256?(map_field(child, :quality_receipt_sha256))
      "registered_action" -> is_nil(map_field(child, :quality_receipt_sha256))
      _invalid -> false
    end
  end

  defp v2_composition_input(snapshot, children) do
    children = Enum.filter(children, &(map_field(&1, :status) == "completed"))

    task_upper_bound =
      children
      |> Enum.flat_map(fn child ->
        [map_field(child, :objective), map_field(child, :expected_result)]
      end)
      |> Enum.map(&normalized_input_size/1)
      |> Enum.max(fn -> 0 end)
      |> max(byte_size(@synthesis_shortening_marker))

    observation_upper_bound =
      children
      |> Enum.map(&map_field(&1, :detail))
      |> Enum.map(&normalized_input_size/1)
      |> Enum.max(fn -> 0 end)
      |> max(byte_size(@synthesis_shortening_marker))

    task_floor = byte_size(@synthesis_shortening_marker)

    with {:ok, observation_floor} <- observation_floor_cap(children),
         true <-
           input_projection_fits?(
             v2_input_projection(snapshot, children, task_floor, observation_floor)
           ),
         {:ok, observation_cap} <-
           largest_fitting_input_cap(
             observation_floor,
             max(observation_upper_bound, observation_floor),
             fn cap -> v2_input_projection(snapshot, children, task_floor, cap) end
           ),
         {:ok, task_cap} <-
           largest_fitting_input_cap(
             task_floor,
             task_upper_bound,
             fn cap -> v2_input_projection(snapshot, children, cap, observation_cap) end
           ),
         projection <-
           v2_input_projection(snapshot, children, task_cap, observation_cap),
         true <- input_projection_fits?(projection) do
      {:ok, projection}
    else
      _does_not_fit -> {:error, :fanout_composition_input_too_large}
    end
  end

  defp observation_floor_cap(children) do
    children
    |> Enum.map(&map_field(&1, :detail))
    |> Enum.reduce_while({:ok, 0}, &accumulate_observation_floor/2)
  end

  defp accumulate_observation_floor(value, {:ok, current_floor}) do
    value
    |> normalize_advisory_text()
    |> observation_floor_result(current_floor)
  end

  defp observation_floor_result("", current_floor),
    do: {:cont, {:ok, current_floor}}

  defp observation_floor_result(normalized, current_floor)
       when byte_size(normalized) <= 64,
       do: {:cont, {:ok, max(current_floor, byte_size(normalized))}}

  defp observation_floor_result(normalized, current_floor) do
    normalized
    |> grapheme_prefix(64)
    |> prefixed_observation_floor(current_floor)
  end

  defp prefixed_observation_floor("", _current_floor),
    do: {:halt, {:error, :fanout_composition_input_too_large}}

  defp prefixed_observation_floor(prefix, current_floor) do
    required = byte_size(prefix) + 1 + byte_size(@synthesis_shortening_marker)
    {:cont, {:ok, max(current_floor, required)}}
  end

  defp v2_input_projection(snapshot, children, task_cap, observation_cap) do
    %{
      synthesis_contract_version: SynthesisPolicy.version(),
      title: map_field(snapshot, :title),
      original_request: map_field(snapshot, :original_request),
      status: map_field(snapshot, :status),
      join_outcome: map_field(snapshot, :join_outcome),
      children: Enum.map(children, &v2_composition_child(&1, task_cap, observation_cap))
    }
  end

  defp v2_composition_child(child, task_cap, observation_cap) do
    {objective, objective_shortened?} =
      bounded_synthesis_input(map_field(child, :objective), task_cap)

    {expected_result, expected_result_shortened?} =
      optional_bounded_synthesis_input(map_field(child, :expected_result), task_cap)

    {observation, observation_shortened?} =
      if map_field(child, :status) == "completed" do
        bounded_observation_input(map_field(child, :detail), observation_cap)
      else
        {nil, false}
      end

    %{
      id: map_field(child, :id),
      queue_position: map_field(child, :queue_position),
      title: map_field(child, :title),
      status: map_field(child, :status),
      result_authority: map_field(child, :result_authority),
      quality_receipt_sha256: map_field(child, :quality_receipt_sha256),
      effect_receipt_ref: map_field(child, :effect_receipt_ref),
      objective: objective,
      objective_shortened: objective_shortened?,
      expected_result: expected_result,
      expected_result_shortened: expected_result_shortened?,
      accepted_observation: observation,
      accepted_observation_shortened: observation_shortened?
    }
  end

  defp optional_bounded_synthesis_input(value, _cap) when value in [nil, ""],
    do: {nil, false}

  defp optional_bounded_synthesis_input(value, cap), do: bounded_synthesis_input(value, cap)

  defp bounded_observation_input(value, cap) do
    normalized = normalize_advisory_text(value)

    if byte_size(normalized) <= cap do
      {normalized, false}
    else
      prefix_budget = max(cap - byte_size(@synthesis_shortening_marker) - 1, 0)
      prefix = grapheme_prefix(normalized, prefix_budget)

      shortened =
        if prefix == "",
          do: @synthesis_shortening_marker,
          else: prefix <> " " <> @synthesis_shortening_marker

      {shortened, true}
    end
  end

  defp bounded_synthesis_input(value, cap) do
    normalized = normalize_advisory_text(value)

    if byte_size(normalized) <= cap do
      {normalized, false}
    else
      prefix_budget = max(cap - byte_size(@synthesis_shortening_marker) - 1, 0)
      prefix = readable_prefix(normalized, prefix_budget)

      shortened =
        if prefix == "",
          do: @synthesis_shortening_marker,
          else: prefix <> " " <> @synthesis_shortening_marker

      {shortened, true}
    end
  end

  defp normalized_input_size(value) when value in [nil, ""], do: 0
  defp normalized_input_size(value), do: value |> normalize_advisory_text() |> byte_size()

  defp largest_fitting_input_cap(lower, upper, builder) when lower <= upper do
    if input_projection_fits?(builder.(lower)) do
      {:ok, search_input_cap(lower, upper, lower, builder)}
    else
      {:error, :fanout_composition_input_too_large}
    end
  end

  defp largest_fitting_input_cap(_lower, _upper, _builder),
    do: {:error, :fanout_composition_input_too_large}

  defp search_input_cap(lower, upper, best, _builder) when lower > upper, do: best

  defp search_input_cap(lower, upper, best, builder) do
    cap = div(lower + upper, 2)

    if input_projection_fits?(builder.(cap)) do
      search_input_cap(cap + 1, upper, cap, builder)
    else
      search_input_cap(lower, cap - 1, best, builder)
    end
  end

  defp input_projection_fits?(projection),
    do: byte_size(CanonicalJSON.encode(projection)) <= @composition_input_bytes

  @doc "Render the deterministic complete-child report used for fallback."
  @spec fallback(snapshot()) :: String.t()
  def fallback(%{version: @v2_version} = snapshot) do
    case fit_v2_fallback_children(snapshot) do
      {:ok, children} -> raw_fallback(snapshot, children)
      {:error, :fanout_report_structure_too_large} -> emergency_fallback(snapshot)
    end
  end

  def fallback(snapshot) when is_map(snapshot) do
    case fit_report_children(snapshot) do
      {:ok, children} -> raw_fallback(snapshot, children)
      {:error, :fanout_report_structure_too_large} -> emergency_fallback(snapshot)
    end
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

  @doc "Validate one layout-v2 advisory synthesis and render it around durable child truth."
  @spec prepare_synthesis(snapshot(), map()) ::
          {:ok,
           %{
             body: String.t(),
             layout: map(),
             synthesis_contract_version: pos_integer(),
             review_verdict: String.t(),
             reviewed_queue_positions: [non_neg_integer()],
             synthesis_sha256: String.t()
           }}
          | {:error, term()}
  def prepare_synthesis(%{version: @v2_version, children: children} = snapshot, result)
      when is_list(children) and is_map(result) do
    with {:ok, normalized} <- normalize_synthesis_result(children, result),
         {:ok, fitted_children} <-
           fit_v2_report_children(snapshot, normalized.sections),
         {:ok, rendered_sections} <-
           select_sections(fitted_children, normalized.sections),
         {:ok, body, synthesis} <-
           raw_v2_composition(
             snapshot,
             fitted_children,
             rendered_sections,
             normalized.advisory_synthesis
           ),
         true <- body == Redactor.redact(body),
         true <- byte_size(body) <= @report_bytes do
      {:ok,
       %{
         body: body,
         layout: %{layout_version: @v2_version, sections: normalized.sections},
         synthesis_contract_version: SynthesisPolicy.version(),
         review_verdict: "accepted",
         reviewed_queue_positions: normalized.reviewed_queue_positions,
         synthesis_sha256: sha256(synthesis)
       }}
    else
      false -> {:error, :invalid_model_fanout_synthesis}
      {:error, _reason} = error -> error
    end
  end

  def prepare_synthesis(_snapshot, _result),
    do: {:error, :invalid_fanout_report_selection}

  defp render_v2_synthesis(%{children: children} = snapshot, sections, synthesis)
       when is_list(children) and is_list(sections) and is_binary(synthesis) do
    with :ok <- validate_completed_partition(children, sections),
         {:ok, fitted_children} <- fit_v2_report_children(snapshot, sections),
         {:ok, rendered_sections} <- select_sections(fitted_children, sections),
         {:ok, body, fitted_synthesis} <-
           raw_v2_composition(snapshot, fitted_children, rendered_sections, synthesis),
         true <- fitted_synthesis == synthesis,
         true <- body == Redactor.redact(body),
         true <- byte_size(body) <= @report_bytes do
      {:ok, body}
    else
      false -> {:error, :invalid_model_fanout_report}
      {:error, _reason} = error -> error
    end
  end

  defp render_v2_synthesis(_snapshot, _sections, _synthesis),
    do: {:error, :invalid_model_fanout_report}

  @doc "Render one already-versioned durable layout through its exact contract version."
  @spec render_composition(snapshot(), map()) :: {:ok, String.t()} | {:error, term()}
  def render_composition(%{children: children} = snapshot, layout)
      when is_list(children) and is_map(layout) do
    with {:ok, normalized} <- normalize_persisted_layout(layout),
         :ok <- validate_completed_partition(children, normalized.sections),
         {:ok, fitted_children} <- fit_report_children(snapshot),
         {:ok, rendered_sections} <- select_sections(fitted_children, normalized.sections) do
      body = raw_composition(snapshot, fitted_children, rendered_sections)

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
    with {:ok, normalized} <-
           normalize_selection_provenance("deterministic_fallback", provenance),
         true <- report_generation(snapshot) == normalized.layout_version do
      cond do
        body != Redactor.redact(body) -> {:error, :unredacted_fanout_report}
        body != fallback(snapshot) -> {:error, :invalid_deterministic_fanout_report}
        true -> :ok
      end
    else
      false -> {:error, :fanout_report_layout_generation_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def validate_selected_body(snapshot, "model", body, provenance)
      when is_map(snapshot) and is_binary(body) and is_map(provenance) do
    case normalize_selection_provenance("model", provenance) do
      {:ok, %{layout_version: @v2_version} = normalized} ->
        validate_v2_selected_body(snapshot, body, normalized)

      {:ok, normalized} ->
        with true <- report_generation(snapshot) == normalized.layout_version,
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

      {:error, _reason} = error ->
        error
    end
  end

  def validate_selected_body(_snapshot, _source, _body, _provenance),
    do: {:error, :invalid_fanout_report_selection}

  defp validate_v2_selected_body(%{version: @v2_version} = snapshot, body, provenance) do
    with {:ok, synthesis} <- extract_v2_synthesis(body),
         true <- sha256(synthesis) == provenance.synthesis_sha256,
         {:ok, expected_body} <-
           render_v2_synthesis(snapshot, provenance.sections, synthesis),
         true <- body == expected_body do
      :ok
    else
      false -> {:error, :invalid_model_fanout_report}
      {:error, _reason} = error -> error
    end
  end

  defp validate_v2_selected_body(_snapshot, _body, _provenance),
    do: {:error, :invalid_fanout_report_input}

  defp extract_v2_synthesis(body) do
    opening = "Model-authored advisory synthesis:\n\n> "

    closing =
      "\n\nEffect verification comes only from the authoritative child-results appendix below."

    with [before, after_opening] <- :binary.split(body, opening, [:global]),
         true <- before != "",
         [synthesis, after_closing] <- :binary.split(after_opening, closing, [:global]),
         true <- synthesis != "" and after_closing != "",
         {:ok, normalized} <- normalize_advisory_synthesis(synthesis),
         true <- normalized == synthesis do
      {:ok, synthesis}
    else
      _invalid -> {:error, :invalid_model_fanout_report}
    end
  end

  @doc "Normalize the only content-free provenance allowed on a selected report event."
  @spec normalize_selection_provenance(String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def normalize_selection_provenance("model", provenance) when is_map(provenance) do
    case provenance_field(provenance, :layout_version) do
      @v2_version -> normalize_v2_model_provenance(provenance)
      _v1_or_invalid -> normalize_v1_model_provenance(provenance)
    end
  end

  def normalize_selection_provenance("deterministic_fallback", provenance)
      when is_map(provenance) do
    normalize_fallback_provenance(provenance)
  end

  def normalize_selection_provenance(_source, _provenance),
    do: {:error, :invalid_fanout_report_provenance}

  @doc "Derive exact generation-matched provenance for one deterministic fallback reason."
  @spec fallback_provenance(snapshot(), atom() | String.t()) ::
          {:ok, map()} | {:error, term()}
  def fallback_provenance(snapshot, reason) when is_map(snapshot) do
    reason = if is_atom(reason), do: Atom.to_string(reason), else: reason

    provenance =
      case report_generation(snapshot) do
        @v2_version ->
          %{
            fallback_reason: reason,
            layout_version: @v2_version,
            synthesis_contract_version: SynthesisPolicy.version(),
            synthesis_outcome:
              if(reason in @unresolved_fallback_reasons, do: "unresolved", else: "not_run")
          }

        @version ->
          %{fallback_reason: reason, layout_version: @layout_version}

        _unknown ->
          %{}
      end

    normalize_selection_provenance("deterministic_fallback", provenance)
  end

  def fallback_provenance(_snapshot, _reason),
    do: {:error, :invalid_fanout_report_input}

  defp normalize_v1_model_provenance(provenance) do
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

  defp normalize_v2_model_provenance(provenance) do
    with true <-
           map_size(provenance) == 9 and
             provenance_keys(provenance) ==
               ~w[
                 layout_version model model_profile provider review_verdict
                 reviewed_queue_positions sections synthesis_contract_version synthesis_sha256
               ],
         {:ok, profile} <-
           provenance_identifier(provenance_field(provenance, :model_profile), 120),
         {:ok, provider} <- provenance_identifier(provenance_field(provenance, :provider), 120),
         {:ok, model} <- provenance_identifier(provenance_field(provenance, :model), 240),
         {:ok, layout} <-
           normalize_v2_layout(%{
             layout_version: provenance_field(provenance, :layout_version),
             sections: provenance_field(provenance, :sections)
           }),
         true <-
           provenance_field(provenance, :synthesis_contract_version) ==
             SynthesisPolicy.version(),
         "accepted" <- provenance_field(provenance, :review_verdict),
         {:ok, positions} <-
           normalize_reviewed_positions(
             provenance_field(provenance, :reviewed_queue_positions),
             layout.sections
           ),
         synthesis_sha when is_binary(synthesis_sha) <-
           provenance_field(provenance, :synthesis_sha256),
         true <- sha256?(synthesis_sha) do
      {:ok,
       %{
         model_profile: profile,
         provider: provider,
         model: model,
         layout_version: @v2_version,
         sections: layout.sections,
         synthesis_contract_version: SynthesisPolicy.version(),
         review_verdict: "accepted",
         reviewed_queue_positions: positions,
         synthesis_sha256: synthesis_sha
       }}
    else
      _invalid -> {:error, :invalid_fanout_report_provenance}
    end
  end

  defp normalize_fallback_provenance(provenance) do
    case provenance_field(provenance, :layout_version) do
      @v2_version -> normalize_v2_fallback_provenance(provenance)
      _v1_or_missing -> normalize_v1_fallback_provenance(provenance)
    end
  end

  defp normalize_v1_fallback_provenance(provenance) do
    reason = provenance_field(provenance, :fallback_reason)
    normalized_reason = if is_atom(reason), do: Atom.to_string(reason), else: reason

    version = provenance_field(provenance, :layout_version) || @layout_version
    keys = provenance_keys(provenance)

    cond do
      keys not in [["fallback_reason"], ~w[fallback_reason layout_version]] ->
        {:error, :invalid_fanout_report_provenance}

      map_size(provenance) != length(keys) ->
        {:error, :invalid_fanout_report_provenance}

      normalized_reason not in @v1_fallback_reasons ->
        {:error, :invalid_fanout_report_provenance}

      version != @layout_version ->
        {:error, :unsupported_fanout_report_layout_version}

      true ->
        {:ok, %{fallback_reason: normalized_reason, layout_version: @layout_version}}
    end
  end

  defp normalize_v2_fallback_provenance(provenance) do
    reason = provenance_field(provenance, :fallback_reason)
    reason = if is_atom(reason), do: Atom.to_string(reason), else: reason
    outcome = provenance_field(provenance, :synthesis_outcome)

    expected_outcome =
      if reason in @unresolved_fallback_reasons,
        do: "unresolved",
        else: "not_run"

    with true <-
           map_size(provenance) == 4 and
             provenance_keys(provenance) ==
               ~w[
                 fallback_reason layout_version synthesis_contract_version synthesis_outcome
               ],
         true <- reason in @v2_fallback_reasons,
         @v2_version <- provenance_field(provenance, :layout_version),
         true <-
           provenance_field(provenance, :synthesis_contract_version) ==
             SynthesisPolicy.version(),
         ^expected_outcome <- outcome do
      {:ok,
       %{
         fallback_reason: reason,
         layout_version: @v2_version,
         synthesis_contract_version: SynthesisPolicy.version(),
         synthesis_outcome: outcome
       }}
    else
      _invalid -> {:error, :invalid_fanout_report_provenance}
    end
  end

  @doc "Bind the selected source and every normalized provenance field."
  @spec selection_digest(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def selection_digest(source, provenance) when is_binary(source) and is_map(provenance) do
    with {:ok, normalized} <- normalize_selection_provenance(source, provenance) do
      domain =
        if provenance_field(normalized, :layout_version) == @v2_version,
          do: @v2_selection_digest_domain,
          else: @selection_digest_domain

      digest =
        :sha256
        |> :crypto.hash([
          domain,
          CanonicalJSON.encode(%{source: source, provenance: normalized})
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
      length(children) > @max_children ->
        {:error, :fanout_report_child_limit_exceeded}

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

  defp normalize_synthesis_result(children, result) do
    with true <-
           map_size(result) == 3 and
             provenance_keys(result) == ~w[advisory_synthesis review sections],
         {:ok, sections} <- normalize_sections(provenance_field(result, :sections)),
         :ok <- validate_completed_partition(children, sections),
         {:ok, synthesis} <-
           normalize_advisory_synthesis(provenance_field(result, :advisory_synthesis)),
         {:ok, reviewed_queue_positions} <-
           normalize_synthesis_review(children, provenance_field(result, :review)) do
      {:ok,
       %{
         sections: sections,
         advisory_synthesis: synthesis,
         reviewed_queue_positions: reviewed_queue_positions
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_fanout_report_synthesis_selection}
    end
  end

  defp normalize_synthesis_review(children, review) when is_map(review) do
    expected_positions = completed_positions(children)

    with true <-
           map_size(review) == 3 and
             provenance_keys(review) ==
               ~w[covered_queue_positions rule_results verdict],
         "accepted" <- provenance_field(review, :verdict),
         ^expected_positions <- provenance_field(review, :covered_queue_positions),
         :ok <- normalize_synthesis_rule_results(provenance_field(review, :rule_results)) do
      {:ok, expected_positions}
    else
      _invalid -> {:error, :unresolved_fanout_report_synthesis}
    end
  end

  defp normalize_synthesis_review(_children, _review),
    do: {:error, :invalid_fanout_report_synthesis_review}

  defp normalize_synthesis_rule_results(results) when is_list(results) do
    normalized =
      Enum.map(results, fn result ->
        if is_map(result) and map_size(result) == 2 and
             provenance_keys(result) == ~w[rule_id verdict] do
          {provenance_field(result, :rule_id), provenance_field(result, :verdict)}
        else
          :invalid
        end
      end)

    expected = Enum.map(SynthesisPolicy.rule_ids(), &{&1, "satisfied"})
    if normalized == expected, do: :ok, else: {:error, :unresolved_fanout_report_synthesis}
  end

  defp normalize_synthesis_rule_results(_results),
    do: {:error, :invalid_fanout_report_synthesis_review}

  defp normalize_advisory_synthesis(value) when is_binary(value) do
    if Redactor.redact(value) == value do
      normalized = normalize_unredacted_advisory_text(value)

      cond do
        normalized == "" ->
          {:error, :empty_fanout_report_synthesis}

        byte_size(normalized) > @synthesis_bytes ->
          {:error, :fanout_report_synthesis_too_large}

        true ->
          {:ok, normalized}
      end
    else
      {:error, :unredacted_fanout_report_synthesis}
    end
  end

  defp normalize_advisory_synthesis(_value),
    do: {:error, :invalid_fanout_report_synthesis}

  defp completed_positions(children) do
    children
    |> Enum.filter(&(map_field(&1, :status) == "completed"))
    |> Enum.map(&map_field(&1, :queue_position))
    |> Enum.sort()
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

  defp normalize_v2_layout(layout) do
    with true <-
           map_size(layout) == 2 and
             provenance_keys(layout) == ~w[layout_version sections],
         @v2_version <- provenance_field(layout, :layout_version),
         {:ok, sections} <- normalize_sections(provenance_field(layout, :sections)) do
      {:ok, %{layout_version: @v2_version, sections: sections}}
    else
      version when is_integer(version) -> {:error, :unsupported_fanout_report_layout_version}
      _invalid -> {:error, :invalid_fanout_report_composition_selection}
    end
  end

  defp normalize_reviewed_positions(positions, sections) when is_list(positions) do
    selected = sections |> Enum.flat_map(& &1.ordered_queue_positions) |> Enum.sort()

    if positions == selected and Enum.all?(positions, &(is_integer(&1) and &1 >= 0)) and
         length(Enum.uniq(positions)) == length(positions) do
      {:ok, positions}
    else
      {:error, :invalid_fanout_report_reviewed_positions}
    end
  end

  defp normalize_reviewed_positions(_positions, _sections),
    do: {:error, :invalid_fanout_report_reviewed_positions}

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
      Enum.map_join(children, "\n", &child_reference_line/1)
  end

  defp v2_attention_section([]), do: nil

  defp v2_attention_section(children) do
    "Attention required (not model-arranged):\n" <>
      Enum.map_join(children, "\n", fn child ->
        position = map_field(child, :queue_position)
        title = truncate_utf8(map_field(child, :title), @rendered_title_bytes)
        objective = truncate_utf8(map_field(child, :objective), @rendered_objective_bytes)

        "- Child #{position + 1}: title=#{Jason.encode!(title)}; " <>
          "status=#{Jason.encode!(map_field(child, :status))}; " <>
          "objective=#{Jason.encode!(objective)}; see the authoritative child result below."
      end)
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
      "\nSee the authoritative child results below."
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
    title = child |> map_field(:title) |> inline_bounded_text(@rendered_title_bytes)
    objective = child |> map_field(:objective) |> inline_bounded_text(@rendered_objective_bytes)
    Jason.encode!(title) <> " (objective: " <> Jason.encode!(objective) <> ")"
  end

  defp child_reference_line(child) do
    position = map_field(child, :queue_position)
    title = inline_bounded_text(map_field(child, :title), @rendered_title_bytes)
    objective = inline_bounded_text(map_field(child, :objective), @rendered_objective_bytes)

    "- Child #{position + 1}: #{title} [#{map_field(child, :status)}]\n" <>
      "  Objective: #{objective}\n" <>
      "  See the authoritative child result below."
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

  defp v2_child_envelopes(children, effect_evidence_refs) do
    {:ok,
     Enum.map(children, fn child ->
       %{
         id: child.id,
         queue_position: child.queue_position,
         title: bounded_characters(child.title, 200),
         objective: bounded_characters(child.objective, 4_000),
         expected_result: v2_expected_result(child.acceptance_criteria),
         status: child.status,
         detail: terminal_detail(child),
         effect_receipt_ref: evidence_ref(effect_evidence_refs, child.id)
       }
     end)}
  end

  defp bind_child_authorities(envelopes, child_authorities) do
    envelopes
    |> Enum.reduce_while({:ok, []}, fn envelope, {:ok, bound} ->
      case normalized_child_authority(Map.get(child_authorities, envelope.id)) do
        {:ok, authority} -> {:cont, {:ok, [Map.merge(envelope, authority) | bound]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bound} -> {:ok, Enum.reverse(bound)}
      {:error, _reason} = error -> error
    end
  end

  defp normalized_child_authority(authority) when is_map(authority) do
    keys = provenance_keys(authority)
    result_authority = provenance_field(authority, :result_authority)
    receipt = provenance_field(authority, :quality_receipt_sha256)

    cond do
      map_size(authority) != 2 or
          keys != ~w[quality_receipt_sha256 result_authority] ->
        {:error, :invalid_fanout_report_child_authority}

      result_authority not in @result_authorities ->
        {:error, :invalid_fanout_report_child_authority}

      result_authority == "reviewed_advisory" and not sha256?(receipt) ->
        {:error, :invalid_fanout_report_quality_receipt}

      result_authority != "reviewed_advisory" and not is_nil(receipt) ->
        {:error, :invalid_fanout_report_quality_receipt}

      true ->
        {:ok,
         %{
           result_authority: result_authority,
           quality_receipt_sha256: receipt
         }}
    end
  end

  defp normalized_child_authority(_authority),
    do: {:error, :invalid_fanout_report_child_authority}

  defp sha256?(value) when is_binary(value), do: Regex.match?(@sha256_pattern, value)
  defp sha256?(_value), do: false

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

  defp v2_expected_result(criteria) do
    case AcceptanceCriteria.decode(criteria) do
      {:ok, %{"summary" => summary}} when is_binary(summary) ->
        bounded_characters(summary, 500)

      _other ->
        nil
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
      text -> text
    end
  end

  defp composition_child(child) do
    detail = map_field(child, :detail) || ""
    normalized_detail = normalize_advisory_text(detail)
    excerpt = truncate_utf8(normalized_detail, @composition_detail_bytes)

    %{
      queue_position: map_field(child, :queue_position),
      title: advisory_text(map_field(child, :title), @composition_child_title_bytes),
      objective:
        advisory_text(
          map_field(child, :objective),
          @composition_child_objective_bytes
        ),
      status: map_field(child, :status),
      detail_excerpt: excerpt,
      detail_excerpt_truncated: byte_size(normalized_detail) > @composition_detail_bytes
    }
  end

  defp advisory_text(value, limit),
    do: value |> normalize_advisory_text() |> truncate_utf8(limit)

  defp normalize_advisory_text(value) do
    value
    |> Redactor.redact()
    |> normalize_unredacted_advisory_text()
  end

  defp normalize_unredacted_advisory_text(value) do
    value
    |> to_string()
    |> String.to_charlist()
    |> Enum.map(fn
      codepoint when codepoint < 0x20 or codepoint == 0x7F -> ?\s
      codepoint -> codepoint
    end)
    |> List.to_string()
    |> String.split()
    |> Enum.join(" ")
  end

  defp raw_fallback(%{version: @v2_version} = snapshot, children) do
    snapshot = Map.put(snapshot, :children, children)

    [
      v2_heading(snapshot),
      status_totals(children),
      v2_attention_section(Enum.reject(children, &(map_field(&1, :status) == "completed"))),
      "No model-authored advisory synthesis was selected.",
      "Effect verification comes only from the authoritative child-results appendix below.",
      v2_authoritative_appendix(children)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp raw_fallback(snapshot, children) do
    heading =
      "#{map_field(snapshot, :title)} — " <>
        "#{map_field(snapshot, :join_outcome) || map_field(snapshot, :status)}"

    heading <> "\n\n" <> authoritative_appendix(snapshot, children)
  end

  defp raw_composition(snapshot, children, rendered_sections) do
    snapshot
    |> Map.put(:children, children)
    |> deterministic_synthesis(rendered_sections)
    |> Kernel.<>("\n\n" <> v1_authoritative_appendix(children))
  end

  defp raw_v2_composition(snapshot, children, rendered_sections, synthesis) do
    prefix = v2_deterministic_prefix(Map.put(snapshot, :children, children), rendered_sections)

    suffix =
      "\n\nEffect verification comes only from the authoritative child-results appendix below." <>
        "\n\n" <> v2_authoritative_appendix(children)

    fixed = prefix <> "\n\nModel-authored advisory synthesis:\n\n> " <> suffix
    allowance = min(@synthesis_bytes, @report_bytes - byte_size(fixed))

    with {:ok, fitted_synthesis} <- fit_report_synthesis(synthesis, allowance) do
      {:ok,
       prefix <>
         "\n\nModel-authored advisory synthesis:\n\n> " <>
         fitted_synthesis <>
         suffix, fitted_synthesis}
    end
  end

  defp v2_deterministic_prefix(snapshot, rendered_sections) do
    children = map_field(snapshot, :children)
    attention = Enum.reject(children, &(map_field(&1, :status) == "completed"))

    [
      v2_heading(snapshot),
      status_totals(children),
      v2_attention_section(attention),
      relationship_sections(rendered_sections)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp fit_report_synthesis(_synthesis, allowance) when allowance <= 0,
    do: {:error, :fanout_report_structure_too_large}

  defp fit_report_synthesis(synthesis, allowance) when byte_size(synthesis) <= allowance,
    do: {:ok, synthesis}

  defp fit_report_synthesis(_synthesis, _allowance),
    do: {:error, :fanout_report_synthesis_too_large}

  defp fit_report_children(%{children: children} = snapshot) when is_list(children) do
    cond do
      report_pair_fits?(snapshot, children) ->
        {:ok, children}

      report_pair_fits?(snapshot, marker_floor_children(children)) ->
        largest_fitting_detail_cap(snapshot, children)

      true ->
        {:error, :fanout_report_structure_too_large}
    end
  end

  defp fit_report_children(_snapshot), do: {:error, :fanout_report_structure_too_large}

  defp fit_v2_fallback_children(%{children: children} = snapshot) when is_list(children) do
    cond do
      v2_fallback_fits?(snapshot, children) ->
        {:ok, children}

      v2_fallback_fits?(snapshot, marker_floor_children(children)) ->
        largest_fitting_v2_fallback_detail_cap(snapshot, children)

      true ->
        {:error, :fanout_report_structure_too_large}
    end
  end

  defp fit_v2_fallback_children(_snapshot),
    do: {:error, :fanout_report_structure_too_large}

  defp v2_fallback_fits?(snapshot, children),
    do: byte_size(raw_fallback(snapshot, children)) <= @report_bytes

  defp largest_fitting_v2_fallback_detail_cap(snapshot, children) do
    floor =
      children
      |> Enum.map(&byte_size(truncation_marker(&1)))
      |> Enum.max(fn -> 0 end)

    ceiling =
      children
      |> Enum.map(&(map_field(&1, :detail) || ""))
      |> Enum.map(&byte_size/1)
      |> Enum.max(fn -> floor end)

    best = marker_floor_children(children)
    {:ok, search_v2_fallback_detail_cap(snapshot, children, floor, ceiling, best)}
  end

  defp search_v2_fallback_detail_cap(_snapshot, _children, lower, upper, best)
       when lower > upper,
       do: best

  defp search_v2_fallback_detail_cap(snapshot, children, lower, upper, best) do
    cap = div(lower + upper, 2)
    candidate = Enum.map(children, &fit_child_detail(&1, cap))

    if v2_fallback_fits?(snapshot, candidate) do
      search_v2_fallback_detail_cap(snapshot, children, cap + 1, upper, candidate)
    else
      search_v2_fallback_detail_cap(snapshot, children, lower, cap - 1, best)
    end
  end

  defp fit_v2_report_children(%{children: children} = snapshot, sections)
       when is_list(children) and is_list(sections) do
    with {:ok, fallback_children} <- fit_v2_fallback_children(snapshot),
         {:ok, model_children} <- fit_v2_model_children(snapshot, children, sections),
         true <- model_allocation_not_worse?(children, fallback_children, model_children) do
      {:ok, model_children}
    else
      false -> {:error, :fanout_report_model_displaces_authoritative_evidence}
      {:error, _reason} = error -> error
    end
  end

  defp fit_v2_report_children(_snapshot, _sections),
    do: {:error, :fanout_report_structure_too_large}

  defp fit_v2_model_children(snapshot, children, sections) do
    cond do
      v2_report_structure_fits?(snapshot, children, sections) ->
        {:ok, children}

      v2_report_structure_fits?(snapshot, marker_floor_children(children), sections) ->
        largest_fitting_v2_detail_cap(snapshot, children, sections)

      true ->
        {:error, :fanout_report_structure_too_large}
    end
  end

  defp model_allocation_not_worse?(original, fallback, model)
       when length(original) == length(fallback) and length(original) == length(model) do
    original
    |> Enum.zip(fallback)
    |> Enum.zip(model)
    |> Enum.all?(fn {{source, baseline}, candidate} ->
      same_child? =
        map_field(source, :id) == map_field(baseline, :id) and
          map_field(source, :id) == map_field(candidate, :id)

      unchanged_context? =
        Enum.all?([:title, :objective], fn field ->
          map_field(candidate, field) == map_field(baseline, field)
        end)

      same_child? and unchanged_context? and
        retained_detail_bytes(candidate, source) >= retained_detail_bytes(baseline, source)
    end)
  end

  defp model_allocation_not_worse?(_original, _fallback, _model), do: false

  defp retained_detail_bytes(child, original) do
    detail = map_field(child, :detail) || ""
    original_detail = map_field(original, :detail) || ""
    marker = truncation_marker(original)

    cond do
      detail == original_detail ->
        byte_size(original_detail)

      detail == marker ->
        0

      String.ends_with?(detail, " " <> marker) ->
        byte_size(detail) - byte_size(marker) - 1

      true ->
        -1
    end
  end

  defp v2_report_structure_fits?(snapshot, children, sections) do
    case select_sections(children, sections) do
      {:ok, rendered_sections} ->
        prefix =
          v2_deterministic_prefix(Map.put(snapshot, :children, children), rendered_sections)

        fixed =
          prefix <>
            "\n\nModel-authored advisory synthesis:\n\n> " <>
            "\n\nEffect verification comes only from the authoritative child-results appendix below." <>
            "\n\n" <> v2_authoritative_appendix(children)

        byte_size(fixed) < @report_bytes

      {:error, _reason} ->
        false
    end
  end

  defp largest_fitting_v2_detail_cap(snapshot, children, sections) do
    floor =
      children
      |> Enum.map(&byte_size(truncation_marker(&1)))
      |> Enum.max(fn -> 0 end)

    ceiling =
      children
      |> Enum.map(&(map_field(&1, :detail) || ""))
      |> Enum.map(&byte_size/1)
      |> Enum.max(fn -> floor end)

    best = marker_floor_children(children)
    {:ok, search_v2_detail_cap(snapshot, children, sections, floor, ceiling, best)}
  end

  defp search_v2_detail_cap(_snapshot, _children, _sections, lower, upper, best)
       when lower > upper,
       do: best

  defp search_v2_detail_cap(snapshot, children, sections, lower, upper, best) do
    cap = div(lower + upper, 2)
    candidate = Enum.map(children, &fit_child_detail(&1, cap))

    if v2_report_structure_fits?(snapshot, candidate, sections) do
      search_v2_detail_cap(snapshot, children, sections, cap + 1, upper, candidate)
    else
      search_v2_detail_cap(snapshot, children, sections, lower, cap - 1, best)
    end
  end

  defp report_pair_fits?(snapshot, children) do
    fallback = raw_fallback(snapshot, children)
    worst_model = raw_composition(snapshot, children, worst_case_sections(children))

    byte_size(fallback) <= @report_bytes and byte_size(worst_model) <= @report_bytes
  end

  defp worst_case_sections(children) do
    children
    |> Enum.filter(&(map_field(&1, :status) == "completed"))
    |> Enum.map(&%{relationship: "independent", children: [&1]})
  end

  defp marker_floor_children(children) do
    Enum.map(children, fn child ->
      marker = truncation_marker(child)
      detail = map_field(child, :detail) || ""

      if byte_size(detail) <= byte_size(marker),
        do: child,
        else: Map.put(child, :detail, marker)
    end)
  end

  defp largest_fitting_detail_cap(snapshot, children) do
    floor =
      children
      |> Enum.map(&byte_size(truncation_marker(&1)))
      |> Enum.max(fn -> 0 end)

    ceiling =
      children
      |> Enum.map(&(map_field(&1, :detail) || ""))
      |> Enum.map(&byte_size/1)
      |> Enum.max(fn -> floor end)

    best = marker_floor_children(children)
    {:ok, search_detail_cap(snapshot, children, floor, ceiling, best)}
  end

  defp search_detail_cap(_snapshot, _children, lower, upper, best) when lower > upper,
    do: best

  defp search_detail_cap(snapshot, children, lower, upper, best) do
    cap = div(lower + upper, 2)
    candidate = Enum.map(children, &fit_child_detail(&1, cap))

    if report_pair_fits?(snapshot, candidate) do
      search_detail_cap(snapshot, children, cap + 1, upper, candidate)
    else
      search_detail_cap(snapshot, children, lower, cap - 1, best)
    end
  end

  defp fit_child_detail(child, cap) do
    detail = map_field(child, :detail) || ""

    if byte_size(detail) <= cap,
      do: child,
      else: Map.put(child, :detail, truncated_detail(detail, truncation_marker(child), cap))
  end

  defp truncation_marker(child) do
    "… [truncated for report size; full result: Objective #{map_field(child, :id)}]"
  end

  defp truncated_detail(_detail, marker, cap) when cap <= byte_size(marker), do: marker

  defp truncated_detail(detail, marker, cap) do
    prefix_budget = cap - byte_size(marker) - 1
    prefix = readable_prefix(detail, prefix_budget)

    if prefix == "", do: marker, else: prefix <> " " <> marker
  end

  defp readable_prefix(_detail, budget) when budget <= 0, do: ""

  defp readable_prefix(detail, budget) do
    prefix = grapheme_prefix(detail, budget)
    graphemes = String.graphemes(prefix)

    boundary =
      graphemes
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {grapheme, index}, last ->
        if String.trim(grapheme) == "", do: index, else: last
      end)

    candidate =
      case boundary do
        nil -> prefix
        0 -> prefix
        index -> graphemes |> Enum.take(index) |> Enum.join()
      end

    String.trim_trailing(candidate)
  end

  defp grapheme_prefix(value, limit) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {collected, used} ->
      next = used + byte_size(grapheme)

      if next <= limit,
        do: {:cont, {[grapheme | collected], next}},
        else: {:halt, {collected, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp emergency_fallback(%{version: @v2_version} = snapshot) do
    heading = v2_heading(snapshot)

    children = map_field(snapshot, :children) || []

    references =
      Enum.map_join(children, "\n", fn child ->
        "- #{glyph(map_field(child, :status))} Child #{map_field(child, :queue_position) + 1} " <>
          "[#{map_field(child, :status)}]; Objective #{map_field(child, :id)}; " <>
          "full durable result remains on this Objective.\n" <>
          "  #{v2_quality_authority_line(child)}\n" <>
          "  Effect receipt: #{v2_effect_receipt(child)}"
      end)

    [
      heading,
      status_totals(children),
      v2_attention_section(Enum.reject(children, &(map_field(&1, :status) == "completed"))),
      "No model-authored advisory synthesis was selected.",
      "Effect verification comes only from the authoritative child-results appendix below.",
      "Authoritative child result references (ordered):\n" <> references
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp emergency_fallback(snapshot) do
    heading =
      "#{inline_bounded_text(map_field(snapshot, :title), @rendered_title_bytes)} — " <>
        "#{map_field(snapshot, :join_outcome) || map_field(snapshot, :status)}"

    children = map_field(snapshot, :children) || []

    references =
      Enum.map_join(children, "\n", fn child ->
        "- #{glyph(map_field(child, :status))} Child #{map_field(child, :queue_position) + 1} " <>
          "[#{map_field(child, :status)}]; Objective #{map_field(child, :id)}; " <>
          "full durable result remains on this Objective.\n" <>
          "  Effect receipt: #{effect_receipt(map_field(child, :effect_receipt_ref))}"
      end)

    heading <> "\n\nAuthoritative child result references (ordered):\n" <> references
  end

  defp v2_heading(snapshot) do
    "title=#{Jason.encode!(map_field(snapshot, :title))} — " <>
      "#{map_field(snapshot, :join_outcome) || map_field(snapshot, :status)}"
  end

  defp authoritative_appendix(%{version: @v2_version}, children),
    do: v2_authoritative_appendix(children)

  defp authoritative_appendix(_v1_or_legacy, children), do: v1_authoritative_appendix(children)

  defp v1_authoritative_appendix(children) do
    lines =
      Enum.map_join(children, "\n", fn child ->
        "- #{glyph(child.status)} #{child.title} [#{child.status}] — " <>
          "#{observation_label(child)}: #{child.detail}\n" <>
          "  Effect receipt: #{effect_receipt(child.effect_receipt_ref)}"
      end)

    @appendix_heading <> "\n" <> lines
  end

  defp v2_authoritative_appendix(children) do
    lines =
      Enum.map_join(children, "\n", fn child ->
        "- #{glyph(child.status)} title=#{Jason.encode!(child.title)} " <>
          "[#{child.status}] — #{v2_observation_label(child)}: " <>
          "observation=#{Jason.encode!(child.detail)}\n" <>
          "  #{v2_quality_authority_line(child)}\n" <>
          "  Effect receipt: #{v2_effect_receipt(child)}"
      end)

    @appendix_heading <> "\n" <> lines
  end

  defp v2_observation_label(%{result_authority: "reviewed_advisory"}),
    do: "Reviewed advisory observation (not effect evidence)"

  defp v2_observation_label(%{status: "completed", result_authority: "registered_action"}),
    do: "Registered-action result"

  defp v2_observation_label(%{result_authority: "registered_action"}),
    do: "Registered-action terminal detail (no completed result)"

  defp v2_observation_label(%{
         status: status,
         result_authority: "legacy_unreviewed_advisory"
       })
       when status in ~w[cancelled failed abandoned],
       do: "Terminal detail (no completed result)"

  defp v2_observation_label(%{result_authority: "legacy_unreviewed_advisory"}),
    do: "Legacy unreviewed advisory observation (not effect evidence)"

  defp v2_quality_authority_line(%{
         result_authority: "reviewed_advisory",
         quality_receipt_sha256: digest
       }) do
    "Result authority: reviewed_advisory; quality_receipt_sha256=#{digest}; " <>
      "receipt verifies advisory quality, not effect evidence."
  end

  defp v2_quality_authority_line(%{
         status: "completed",
         result_authority: "registered_action"
       }),
       do: "Result authority: registered_action; advisory quality review is not applicable."

  defp v2_quality_authority_line(%{result_authority: "registered_action"}),
    do:
      "Result authority: registered_action identity verified; no completed-result authority; advisory quality review is not applicable."

  defp v2_quality_authority_line(%{
         status: status,
         result_authority: "legacy_unreviewed_advisory"
       })
       when status in ~w[cancelled failed abandoned],
       do:
         "Result authority: none; no completed result; advisory quality review is not applicable."

  defp v2_quality_authority_line(%{result_authority: "legacy_unreviewed_advisory"}),
    do:
      "Result authority: legacy_unreviewed_advisory; quality receipt absent; advisory output is unreviewed and deterministic fallback is required."

  defp v2_effect_receipt(%{
         status: "completed",
         effect_receipt_ref: nil,
         result_authority: "registered_action"
       }),
       do: "none recorded. Registered-action result has no recorded effect evidence."

  defp v2_effect_receipt(%{effect_receipt_ref: nil, result_authority: "registered_action"}),
    do: "none recorded. No completed registered-action result or recorded effect evidence."

  defp v2_effect_receipt(%{effect_receipt_ref: nil}),
    do: "none recorded. Advisory observation is not effect evidence."

  defp v2_effect_receipt(%{effect_receipt_ref: ref}), do: effect_receipt(ref)

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

  defp map_field(map, key) when is_map(map), do: Map.get(map, key)
  defp map_field(_value, _key), do: nil

  defp bounded_text(nil, _limit), do: ""

  defp bounded_text(value, limit) do
    value
    |> Redactor.redact()
    |> to_string()
    |> truncate_utf8(limit)
  end

  defp bounded_characters(nil, _limit), do: ""

  defp bounded_characters(value, limit) do
    value
    |> Redactor.redact()
    |> to_string()
    |> String.slice(0, limit)
  end

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

  defp sha256(value),
    do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp report_generation(snapshot) do
    case map_field(snapshot, :version) do
      @v2_version -> @v2_version
      @version -> @version
      _unknown -> nil
    end
  end
end
