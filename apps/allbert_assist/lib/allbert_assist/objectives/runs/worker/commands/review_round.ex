defmodule AllbertAssist.Objectives.Runs.Worker.Commands.ReviewRound do
  @moduledoc """
  Private Jido transition for one policy-owned two-critic Worker review round.

  The command coordinates only transient advisory evidence. Local policy and
  receipt validation remain the completion authority; critic output cannot
  revise text, select actions, or create durable state.
  """

  use Jido.Action,
    name: "allbert_objective_direct_answer_worker_review_round",
    description: "Assess one exact Worker candidate with two closed critic groups."

  alias AllbertAssist.Objectives.CanonicalJSON

  alias AllbertAssist.Objectives.Fanout.{
    ReqLLMCritic,
    ReviewRound
  }

  alias AllbertAssist.Objectives.Runs.Worker.{QualityPolicy, QualityReceipt}

  @impl true
  def run(
        %{
          phase: phase,
          runner_context: runner_context
        } = params,
        context
      )
      when phase in [:initial, :final] and is_map(runner_context) do
    state = Map.get(context, :state, %{})
    critic = Map.get(params, :critic, ReqLLMCritic)

    with :ok <- valid_transition(state, phase),
         {:ok, protocol} <- QualityPolicy.review_protocol(),
         {:ok, candidate, response} <- candidate(state, phase),
         {:ok, review} <-
           ReviewRound.run(
             protocol,
             %{"task_contract" => CanonicalJSON.encode(state.task_contract)},
             candidate,
             Map.put(runner_context, :fanout_review_phase, phase),
             critic_implementation: critic,
             deadline_monotonic_ms:
               Map.fetch!(runner_context, :fanout_worker_deadline_monotonic_ms)
           ) do
      transition(state, phase, protocol, review, candidate, response)
    else
      {:error, {:review_round_failed, reason, critic_call_count}}
      when is_atom(reason) and is_integer(critic_call_count) and critic_call_count >= 0 ->
        reason =
          if critic_call_count > 2,
            do: :quality_provider_attempt_bound_exceeded,
            else: reason

        {:ok,
         unresolved(
           state,
           phase,
           reason,
           review_failure_call_count(phase, critic_call_count)
         )}

      {:error, reason} ->
        {:ok, unresolved(state, phase, reason)}
    end
  end

  def run(_params, context) do
    {:ok,
     context
     |> Map.get(:state, %{})
     |> unresolved(:initial, :invalid_quality_review_round_input)}
  end

  defp transition(state, :initial, protocol, %{outcome: :satisfied} = review, candidate, response) do
    accept(state, protocol, review, nil, candidate, response)
  end

  defp transition(
         state,
         :initial,
         _protocol,
         %{outcome: :requires_revision, revision_rule_ids: [_ | _]} = review,
         _candidate,
         _response
       ) do
    {:ok,
     Map.merge(state, %{
       status: :revision_required,
       provider_call_count: 3,
       initial_review: review,
       initial_reviewer_config_sha256: review.reviewer_config_sha256,
       error: nil,
       last_command: :initial_review,
       last_result: {:ok, :revision_required}
     })}
  end

  defp transition(state, :final, protocol, %{outcome: :satisfied} = review, candidate, response) do
    accept(state, protocol, state.initial_review, review, candidate, response)
  end

  defp transition(state, phase, _protocol, _review, _candidate, _response),
    do:
      {:ok,
       unresolved(
         state,
         phase,
         :quality_review_unresolved,
         if(phase == :final, do: 6, else: 3)
       )}

  defp accept(state, protocol, initial_review, final_review, candidate, response) do
    accepted_review = final_review || initial_review
    phase = if(final_review, do: :final, else: :initial)
    provider_call_count = if(final_review, do: 6, else: 3)

    expected_initial_config =
      Map.get(state, :initial_reviewer_config_sha256, initial_review.reviewer_config_sha256)

    with :ok <-
           QualityPolicy.validate_phase_review(
             state.task_contract,
             state.draft_response.message,
             initial_review,
             expected_initial_config
           ),
         :ok <- validate_final_review(state, final_review),
         {:ok, reviewer_config_sha256} <-
           QualityPolicy.reviewer_config_set_sha256(
             initial_review.reviewer_config_sha256,
             final_review && final_review.reviewer_config_sha256
           ),
         {:ok, receipt} <-
           QualityReceipt.build(%{
             objective_id: state.objective_id,
             step_id: state.step_id,
             task_contract_sha256: state.task_contract_sha256,
             rule_catalog_version: QualityPolicy.version(),
             review_protocol_version: protocol.review_protocol_version,
             critic_group_count: accepted_review.critic_group_count,
             rule_group_catalog_version: protocol.rule_group_catalog_version,
             rule_group_catalog_sha256: protocol.rule_group_catalog_sha256,
             reviewer_config_sha256: reviewer_config_sha256,
             draft_call_count: 1,
             initial_critic_call_count: 2,
             revision_call_count: if(final_review, do: 1, else: 0),
             final_critic_call_count: if(final_review, do: 2, else: 0),
             provider_call_count: provider_call_count,
             initial_assessment_sha256: initial_review.assessment_sha256,
             final_assessment_sha256: final_review && final_review.assessment_sha256,
             accepted_assessment_sha256: accepted_review.assessment_sha256,
             verdict: "accepted",
             failed_rule_ids: [],
             final_answer: candidate
           }) do
      response = Map.put(response, :message, candidate)

      {:ok,
       Map.merge(state, %{
         status: :accepted,
         provider_call_count: provider_call_count,
         draft_response: nil,
         revised_response: nil,
         initial_review: nil,
         initial_reviewer_config_sha256: nil,
         error: nil,
         final_answer: candidate,
         quality_receipt: receipt,
         last_command: if(final_review, do: :final_review, else: :initial_review),
         last_result: {:ok, %{response: response, quality_receipt: receipt}}
       })}
    else
      _invalid ->
        {:ok, unresolved(state, phase, :invalid_quality_receipt_binding, provider_call_count)}
    end
  end

  defp candidate(
         %{draft_response: %{message: candidate} = response},
         :initial
       )
       when is_binary(candidate),
       do: {:ok, candidate, response}

  defp candidate(
         %{revised_response: %{message: candidate} = response},
         :final
       )
       when is_binary(candidate),
       do: {:ok, candidate, response}

  defp candidate(_state, _phase), do: {:error, :invalid_quality_review_candidate}

  defp valid_transition(
         %{
           status: :draft,
           provider_call_count: 1,
           task_contract: contract,
           task_contract_sha256: digest
         },
         :initial
       )
       when is_map(contract) and is_binary(digest) do
    validate_contract(contract, digest)
  end

  defp valid_transition(
         %{
           status: :revised,
           provider_call_count: 4,
           initial_review: %{outcome: :requires_revision},
           task_contract: contract,
           task_contract_sha256: digest
         } = state,
         :final
       )
       when is_map(contract) and is_binary(digest) do
    with :ok <- validate_contract(contract, digest),
         :ok <- validate_stored_initial_review(state) do
      :ok
    end
  end

  defp valid_transition(_state, _phase), do: {:error, :invalid_quality_review_transition}

  defp validate_contract(contract, expected_digest) do
    case QualityPolicy.digest(contract) do
      {:ok, ^expected_digest} -> :ok
      _invalid -> {:error, :invalid_quality_task_contract}
    end
  end

  defp validate_stored_initial_review(%{
         task_contract: contract,
         draft_response: %{message: candidate},
         initial_review: review,
         initial_reviewer_config_sha256: expected_config
       }) do
    QualityPolicy.validate_phase_review(contract, candidate, review, expected_config)
  end

  defp validate_stored_initial_review(_state),
    do: {:error, :invalid_quality_phase_review}

  defp validate_final_review(_state, nil), do: :ok

  defp validate_final_review(
         %{task_contract: contract, revised_response: %{message: candidate}},
         review
       ) do
    QualityPolicy.validate_phase_review(
      contract,
      candidate,
      review,
      review.reviewer_config_sha256
    )
  end

  defp validate_final_review(_state, _review),
    do: {:error, :invalid_quality_phase_review}

  defp unresolved(state, phase, reason, provider_call_count \\ nil) do
    Map.merge(state, %{
      status: :unresolved,
      provider_call_count: provider_call_count || Map.get(state, :provider_call_count, 0),
      error: reason,
      last_command: if(phase == :final, do: :final_review, else: :initial_review),
      last_result: {:error, reason}
    })
  end

  defp review_failure_call_count(:initial, critic_call_count), do: 1 + critic_call_count
  defp review_failure_call_count(:final, critic_call_count), do: 4 + critic_call_count
end
