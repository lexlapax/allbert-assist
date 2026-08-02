defmodule AllbertAssist.Objectives.Runs.Worker.Commands.Revise do
  @moduledoc """
  Private Jido transition for the Worker protocol's single allowed revision.

  The registered DirectAnswer action remains the generator boundary. Allbert
  derives its input from the immutable task contract, exact draft bytes, and
  locally merged rule identifiers; the generator does not author a verdict.
  """

  use Jido.Action,
    name: "allbert_objective_direct_answer_worker_revise",
    description: "Revise one Worker draft once from deterministic rule evidence."

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives.ObservationSummary
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy
  alias AllbertAssist.Settings.Store

  @impl true
  def run(%{runner_context: runner_context}, context) when is_map(runner_context) do
    state = Map.get(context, :state, %{})

    with :ok <- valid_transition(state),
         {:ok, prompt} <-
           QualityPolicy.revision_prompt(
             state.task_contract,
             state.draft_response.message,
             state.initial_review.revision_rule_ids
           ),
         :ok <- active(runner_context),
         result <- run_direct_answer(prompt, runner_context) do
      {:ok, transition(state, result)}
    else
      {:error, reason} -> {:ok, unresolved(state, reason)}
    end
  end

  def run(_params, context),
    do: {:ok, unresolved(Map.get(context, :state, %{}), :invalid_quality_revision_input)}

  defp run_direct_answer(prompt, runner_context) do
    runner_context = Map.put(runner_context, :fanout_worker_phase, :revision)

    Store.with_resolved_settings(fn ->
      Runner.run(DirectAnswer, %{text: prompt}, runner_context)
    end)
  end

  defp transition(
         state,
         {:ok,
          %{
            direct_answer: %{source: :model},
            fanout_worker: %{version: 1, provider_call_count: 1}
          } = response}
       ) do
    case normalized_response(response) do
      {:ok, response} ->
        Map.merge(state, %{
          status: :revised,
          provider_call_count: 4,
          revised_response: Map.delete(response, :fanout_worker),
          error: nil,
          last_command: :revise,
          last_result: {:ok, :revised}
        })

      {:error, reason} ->
        unresolved(state, reason, 4)
    end
  end

  defp transition(state, {:ok, response}) when is_map(response) do
    case Map.get(response, :fanout_worker) do
      %{version: 1, provider_call_count: count} when count in [0, 1] ->
        unresolved(state, :quality_model_revision_unavailable, 3 + count)

      %{version: 1, provider_call_count: count} when is_integer(count) and count > 1 ->
        unresolved(state, :quality_provider_attempt_bound_exceeded, 3 + count)

      _missing_or_invalid ->
        unresolved(state, :quality_model_revision_unavailable, 3)
    end
  end

  defp transition(state, {:error, reason}),
    do: unresolved(state, {:quality_revision_failed, reason}, 3)

  defp normalized_response(%{message: message} = response) when is_binary(message) do
    normalized = ObservationSummary.normalize(message)

    if String.trim(normalized) == "",
      do: {:error, :quality_model_revision_unavailable},
      else: {:ok, Map.put(response, :message, normalized)}
  end

  defp normalized_response(_response), do: {:error, :quality_model_revision_unavailable}

  defp valid_transition(%{
         status: :revision_required,
         provider_call_count: 3,
         task_contract: contract,
         task_contract_sha256: digest,
         draft_response: %{message: draft},
         initial_review: %{outcome: :requires_revision, revision_rule_ids: [_ | _]} = review,
         initial_reviewer_config_sha256: expected_config
       })
       when is_map(contract) and is_binary(digest) and is_binary(draft) do
    with {:ok, ^digest} <- QualityPolicy.digest(contract),
         :ok <- QualityPolicy.validate_phase_review(contract, draft, review, expected_config) do
      :ok
    else
      _invalid -> {:error, :invalid_quality_revision_transition}
    end
  end

  defp valid_transition(_state), do: {:error, :invalid_quality_revision_transition}

  defp active(context) do
    case CancelToken.checkpoint(context) do
      :ok -> :ok
      :cancelled -> {:error, :cancelled}
    end
  end

  defp unresolved(state, reason, provider_call_count \\ nil) do
    Map.merge(state, %{
      status: :unresolved,
      provider_call_count: provider_call_count || Map.get(state, :provider_call_count, 0),
      error: reason,
      last_command: :revise,
      last_result: {:error, reason}
    })
  end
end
