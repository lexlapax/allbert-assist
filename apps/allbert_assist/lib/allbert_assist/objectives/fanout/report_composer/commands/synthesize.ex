defmodule AllbertAssist.Objectives.Fanout.ReportComposer.Commands.Synthesize do
  @moduledoc false

  use Jido.Action,
    name: "allbert_fanout_report_synthesize",
    description:
      "Generate, independently review, optionally revise, and verify one bounded fan-out advisory synthesis."

  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy
  alias AllbertAssist.Objectives.Fanout.{ReqLLMCritic, ReviewRound}
  alias AllbertAssist.Objectives.Runs.CancelToken

  @synthesis_contract_version 2

  @impl true
  def run(
        %{
          snapshot: snapshot,
          profile: profile,
          model_context: model_context,
          model_client: model_client,
          deadline_monotonic_ms: deadline_monotonic_ms
        },
        context
      )
      when is_map(snapshot) and is_map(profile) and is_map(model_context) and
             is_atom(model_client) and is_integer(deadline_monotonic_ms) do
    state = Map.get(context, :state, %{})

    result =
      with :ok <- Report.synthesis_eligibility(snapshot),
           {:ok, bounded_input} <- Report.composition_input(snapshot),
           {:ok, protocol} <- SynthesisPolicy.review_protocol() do
        synthesize_and_review(%{
          snapshot: snapshot,
          source_contract: CanonicalJSON.encode(bounded_input),
          protocol: protocol,
          profile: profile,
          model_context: model_context,
          model_client: model_client,
          deadline: deadline_monotonic_ms
        })
      end

    {:ok, terminal_state(state, result)}
  end

  def run(_params, context) do
    {:ok,
     terminal_state(
       Map.get(context, :state, %{}),
       {:error, :invalid_synthesis_agent_input}
     )}
  end

  defp synthesize_and_review(workflow) do
    with :ok <- active(workflow.model_context),
         {:ok, call_context} <- bounded_context(workflow.model_context, workflow.deadline),
         {:ok, {generated, generation_configuration_sha256}} <-
           invoke_generation(workflow, call_context),
         {:ok, initial_candidate} <- prepare_candidate(workflow.snapshot, generated),
         initial_candidate <-
           Map.merge(initial_candidate, %{
             generation_configuration_sha256: generation_configuration_sha256,
             revision_configuration_sha256: nil
           }),
         {:ok, initial_review} <-
           review_candidate(
             workflow.protocol,
             workflow.source_contract,
             initial_candidate.bytes,
             workflow.model_context,
             workflow.deadline,
             :initial
           ) do
      select_or_revise(workflow, initial_candidate, initial_review)
    end
  end

  defp select_or_revise(
         workflow,
         candidate,
         %{outcome: :satisfied, provider_call_count: 2} = review
       ) do
    accepted(candidate, workflow.protocol, review, nil)
  end

  defp select_or_revise(
         workflow,
         initial_candidate,
         %{outcome: :requires_revision, provider_call_count: 2, revision_rule_ids: rule_ids} =
           initial_review
       )
       when is_list(rule_ids) and rule_ids != [] do
    with :ok <- active(workflow.model_context),
         {:ok, call_context} <- bounded_context(workflow.model_context, workflow.deadline),
         {:ok, {revised, revision_configuration_sha256}} <-
           invoke_revision(workflow, initial_candidate.bytes, rule_ids, call_context),
         {:ok, final_candidate} <- phase_prepare_candidate(workflow.snapshot, revised),
         final_candidate <-
           Map.merge(final_candidate, %{
             generation_configuration_sha256: initial_candidate.generation_configuration_sha256,
             revision_configuration_sha256: revision_configuration_sha256
           }),
         {:ok, final_review} <-
           review_candidate(
             workflow.protocol,
             workflow.source_contract,
             final_candidate.bytes,
             workflow.model_context,
             workflow.deadline,
             :final
           ),
         %{outcome: :satisfied, provider_call_count: 2} <- final_review do
      accepted(final_candidate, workflow.protocol, initial_review, final_review)
    else
      {:error, {:phase_review_unresolved, _reason}} = error -> error
      {:error, reason} -> {:error, {:phase_review_unresolved, closed_phase_reason(reason)}}
      _unresolved -> {:error, {:phase_review_unresolved, :final_verification_failed}}
    end
  end

  defp select_or_revise(_workflow, _candidate, _review),
    do: {:error, {:phase_review_unresolved, :invalid_initial_review}}

  defp invoke_generation(workflow, context) do
    context = ProviderAttempt.put_phase(context, :generation)

    workflow
    |> generation_result(context)
    |> normalize_generation_result()
  end

  defp generation_result(workflow, context) do
    if function_exported?(workflow.model_client, :compose_with_provenance, 3) do
      workflow.model_client.compose_with_provenance(
        workflow.snapshot,
        workflow.profile,
        context
      )
    else
      workflow.model_client.compose(workflow.snapshot, workflow.profile, context)
      |> legacy_generation_result()
    end
  end

  defp legacy_generation_result({:ok, selection}) when is_map(selection),
    do: {:ok, %{candidate: selection, configuration_sha256: nil}}

  defp legacy_generation_result(result), do: result

  defp normalize_generation_result({:ok, %{candidate: selection, configuration_sha256: digest}})
       when is_map(selection) and (is_nil(digest) or is_binary(digest)),
       do: normalize_generation_digest(selection, digest)

  defp normalize_generation_result({:error, {:invalid_model_output, _reason}} = error),
    do: error

  defp normalize_generation_result({:error, {:provider_failed, _reason}} = error), do: error
  defp normalize_generation_result({:error, {:profile_unavailable, _reason}} = error), do: error

  defp normalize_generation_result({:error, reason}),
    do: {:error, {:provider_failed, reason}}

  defp normalize_generation_result(invalid),
    do: {:error, {:provider_failed, {:invalid_generation_result, invalid}}}

  defp normalize_generation_digest(selection, nil), do: {:ok, {selection, nil}}

  defp normalize_generation_digest(selection, digest) do
    if sha256?(digest),
      do: {:ok, {selection, digest}},
      else: {:error, {:provider_failed, :invalid_generation_configuration_digest}}
  end

  defp invoke_revision(workflow, candidate, rule_ids, context) do
    context = ProviderAttempt.put_phase(context, :revision)

    cond do
      function_exported?(workflow.model_client, :revise_with_provenance, 5) ->
        workflow.model_client.revise_with_provenance(
          workflow.snapshot,
          candidate,
          rule_ids,
          workflow.profile,
          context
        )
        |> normalize_revision_result()

      function_exported?(workflow.model_client, :revise, 5) ->
        workflow.model_client.revise(
          workflow.snapshot,
          candidate,
          rule_ids,
          workflow.profile,
          context
        )
        |> normalize_legacy_revision_result()

      true ->
        {:error, :revision_implementation_unavailable}
    end
  end

  defp normalize_revision_result({:ok, %{candidate: selection, configuration_sha256: digest}})
       when is_map(selection) and is_binary(digest) do
    if sha256?(digest),
      do: {:ok, {selection, digest}},
      else: {:error, :invalid_revision_configuration_digest}
  end

  defp normalize_revision_result({:error, reason}), do: {:error, reason}

  defp normalize_revision_result(invalid),
    do: {:error, {:invalid_revision_result, invalid}}

  defp normalize_legacy_revision_result({:ok, selection}) when is_map(selection),
    do: {:ok, {selection, nil}}

  defp normalize_legacy_revision_result({:error, reason}), do: {:error, reason}

  defp normalize_legacy_revision_result(invalid),
    do: {:error, {:invalid_revision_result, invalid}}

  defp prepare_candidate(snapshot, selection) do
    with true <- exact_candidate_keys?(selection),
         {:ok, normalized_synthesis} <- normalize_synthesis(selection),
         {:ok, prepared} <-
           Report.prepare_synthesis(snapshot, locally_reviewed(selection, snapshot)),
         true <- prepared.synthesis_sha256 == sha256(normalized_synthesis) do
      {:ok,
       %{
         prepared: prepared,
         bytes:
           CanonicalJSON.encode(%{
             "sections" => canonical_sections(prepared.layout.sections),
             "advisory_synthesis" => normalized_synthesis
           })
       }}
    else
      {:error, reason} -> {:error, {:invalid_model_output, reason}}
      _invalid -> {:error, {:invalid_model_output, :invalid_synthesis_candidate}}
    end
  end

  defp phase_prepare_candidate(snapshot, selection) do
    case prepare_candidate(snapshot, selection) do
      {:ok, candidate} -> {:ok, candidate}
      {:error, reason} -> {:error, {:phase_review_unresolved, closed_phase_reason(reason)}}
    end
  end

  defp review_candidate(protocol, source_contract, candidate, context, deadline, phase) do
    critic_context =
      context
      |> Map.put(:fanout_review_deadline_monotonic_ms, deadline)
      |> Map.put(:review_phase, phase)

    implementation = Map.get(context, :critic_implementation, ReqLLMCritic)

    case ReviewRound.run(
           protocol,
           %{"task_contract" => source_contract},
           candidate,
           critic_context,
           critic_implementation: implementation,
           deadline_monotonic_ms: deadline
         ) do
      {:ok, %{provider_call_count: 2} = review} ->
        {:ok, review}

      {:error, {:review_round_failed, reason, provider_call_count}}
      when is_atom(reason) and is_integer(provider_call_count) and provider_call_count >= 0 ->
        reason =
          if provider_call_count > 2,
            do: :quality_provider_attempt_bound_exceeded,
            else: closed_phase_reason(reason)

        {:error,
         {:phase_review_unresolved,
          %{
            phase: phase,
            reason: reason,
            provider_call_count: review_failure_call_count(phase, provider_call_count)
          }}}

      {:error, reason} ->
        {:error, {:phase_review_unresolved, closed_phase_reason(reason)}}
    end
  end

  defp review_failure_call_count(:initial, critic_call_count), do: 1 + critic_call_count
  defp review_failure_call_count(:final, critic_call_count), do: 4 + critic_call_count

  defp accepted(candidate, protocol, initial_review, final_review) do
    accepted_review = final_review || initial_review
    revised? = not is_nil(final_review)
    revision_call_count = if(revised?, do: 1, else: 0)
    final_critic_call_count = if(revised?, do: final_review.provider_call_count, else: 0)

    provider_call_count =
      1 + initial_review.provider_call_count + revision_call_count + final_critic_call_count

    with {:ok, reviewer_config_sha256} <-
           SynthesisPolicy.reviewer_config_set_sha256(
             initial_review.reviewer_config_sha256,
             final_review && final_review.reviewer_config_sha256
           ) do
      {:ok,
       Map.merge(candidate.prepared, %{
         synthesis_contract_version: @synthesis_contract_version,
         review_protocol_version: protocol.review_protocol_version,
         critic_group_count: accepted_review.critic_group_count,
         rule_group_catalog_version: protocol.rule_group_catalog_version,
         rule_group_catalog_sha256: protocol.rule_group_catalog_sha256,
         reviewer_config_sha256: reviewer_config_sha256,
         generation_call_count: 1,
         initial_critic_call_count: initial_review.provider_call_count,
         revision_call_count: revision_call_count,
         final_critic_call_count: final_critic_call_count,
         provider_call_count: provider_call_count,
         initial_assessment_sha256: initial_review.assessment_sha256,
         final_assessment_sha256: if(revised?, do: final_review.assessment_sha256, else: nil),
         accepted_assessment_sha256: accepted_review.assessment_sha256,
         generation_configuration_sha256: Map.get(candidate, :generation_configuration_sha256),
         revision_configuration_sha256: Map.get(candidate, :revision_configuration_sha256)
       })}
    else
      {:error, reason} -> {:error, {:phase_review_unresolved, reason}}
    end
  end

  defp locally_reviewed(selection, snapshot) do
    Map.put(selection, "review", %{
      "verdict" => "accepted",
      "rule_results" =>
        Enum.map(SynthesisPolicy.rule_ids(), fn rule_id ->
          %{"rule_id" => rule_id, "verdict" => "satisfied"}
        end),
      "covered_queue_positions" => completed_positions(snapshot)
    })
  end

  defp completed_positions(%{children: children}) do
    children
    |> Enum.filter(&(field(&1, :status) == "completed"))
    |> Enum.map(&field(&1, :queue_position))
    |> Enum.sort()
  end

  defp canonical_sections(sections) do
    Enum.map(sections, fn section ->
      %{
        "relationship" => section.relationship,
        "ordered_queue_positions" => section.ordered_queue_positions
      }
    end)
  end

  defp exact_candidate_keys?(selection) do
    selection
    |> Map.keys()
    |> Enum.map(&normalize_key/1)
    |> Enum.sort()
    |> Kernel.==(~w[advisory_synthesis sections])
  end

  defp normalize_synthesis(selection) do
    case field(selection, :advisory_synthesis) do
      value when is_binary(value) ->
        {:ok,
         value
         |> String.to_charlist()
         |> Enum.map(fn
           codepoint when codepoint < 0x20 or codepoint == 0x7F -> ?\s
           codepoint -> codepoint
         end)
         |> List.to_string()
         |> String.split()
         |> Enum.join(" ")}

      _invalid ->
        {:error, :invalid_fanout_report_synthesis}
    end
  end

  defp bounded_context(context, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case {remaining, Map.get(context, :timeout_ms)} do
      {remaining, configured}
      when remaining > 0 and is_integer(configured) and configured > 0 ->
        {:ok, Map.put(context, :timeout_ms, min(remaining, configured))}

      {remaining, nil} when remaining > 0 ->
        {:ok, Map.put(context, :timeout_ms, remaining)}

      {remaining, _configured} when remaining <= 0 ->
        {:error, :review_deadline_exhausted}

      _invalid ->
        {:error, :invalid_synthesis_timeout_bound}
    end
  end

  defp active(context) do
    case CancelToken.checkpoint(context) do
      :ok -> :ok
      :cancelled -> {:error, {:phase_review_unresolved, :review_cancelled}}
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(_key), do: :invalid

  defp closed_phase_reason({:invalid_model_output, _reason}), do: :invalid_revision_candidate
  defp closed_phase_reason({:provider_failed, _reason}), do: :revision_provider_failed
  defp closed_phase_reason({:profile_unavailable, _reason}), do: :revision_profile_unavailable
  defp closed_phase_reason(:review_deadline_exhausted), do: :review_deadline_exhausted
  defp closed_phase_reason(:fanout_plan_deadline_exhausted), do: :review_deadline_exhausted
  defp closed_phase_reason(:review_cancelled), do: :review_cancelled
  defp closed_phase_reason(_reason), do: :phase_review_failed

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    match?({:ok, <<_::256>>}, Base.decode16(value, case: :lower))
  end

  defp sha256?(_value), do: false

  defp terminal_state(state, {:ok, prepared}) do
    Map.merge(state, %{
      status: :accepted,
      prepared: prepared,
      error: nil
    })
  end

  defp terminal_state(state, {:error, reason}) do
    Map.merge(state, %{
      status: :unresolved,
      prepared: nil,
      error: reason
    })
  end
end
