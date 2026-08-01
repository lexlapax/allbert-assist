defmodule AllbertAssist.Objectives.Runs.Worker.Commands.ReviewAndRevise do
  @moduledoc """
  Private Jido command for one bounded worker review-and-revise transition.

  The command accepts only a verified model draft, invokes one prepared
  advisory reviewer, and locally validates the returned rule evidence before
  constructing a transient receipt. It is not a registered Allbert action.
  """

  use Jido.Action,
    name: "allbert_objective_direct_answer_worker_review_and_revise",
    description: "Review and revise one grounded DirectAnswer child draft."

  alias AllbertAssist.Objectives.Runs.Worker.{QualityPolicy, QualityReceipt, ReqLLMReviewer}
  alias AllbertAssist.Settings.Store

  @impl true
  def run(%{runner_context: runner_context} = params, context)
      when is_map(runner_context) do
    state = Map.get(context, :state, %{})
    reviewer = Map.get(params, :reviewer, ReqLLMReviewer)

    with :ok <- valid_transition(state),
         {:ok, digest} <- QualityPolicy.digest(state.task_contract),
         true <- digest == state.task_contract_sha256 do
      review(state, reviewer, runner_context)
    else
      _invalid -> {:ok, unresolved(state, :invalid_quality_review_transition, 1)}
    end
  end

  def run(_params, context) do
    {:ok,
     context
     |> Map.get(:state, %{})
     |> unresolved(:invalid_quality_review_input, 1)}
  end

  defp review(state, reviewer, runner_context) do
    result =
      Store.with_resolved_settings(fn ->
        case safe_prepare(reviewer, state, runner_context) do
          {:ok, prepared} ->
            {:reviewer_invoked, prepared, safe_invoke(reviewer, prepared, runner_context)}

          {:error, reason} ->
            {:reviewer_not_invoked, reason}
        end
      end)

    case result do
      {:reviewer_invoked, prepared, {:ok, reviewed}} ->
        accept_or_unresolve(state, prepared, reviewed)

      {:reviewer_invoked, _prepared, {:error, reason}} ->
        {:ok, unresolved(state, {:quality_reviewer_failed, reason}, 2)}

      {:reviewer_not_invoked, reason} ->
        {:ok, unresolved(state, {:quality_reviewer_unavailable, reason}, 1)}

      {:error, reason} ->
        {:ok, unresolved(state, {:quality_reviewer_unavailable, reason}, 1)}

      _invalid ->
        {:ok, unresolved(state, :invalid_quality_reviewer_result, 1)}
    end
  end

  defp accept_or_unresolve(state, prepared, reviewed) do
    with {:ok, normalized} <- normalize_reviewed(reviewed),
         true <- normalized.verdict == "accepted" and normalized.failed_rule_ids == [],
         reviewer_config_sha256 when is_binary(reviewer_config_sha256) <-
           Map.get(prepared, :reviewer_config_sha256),
         true <- reviewer_config_sha256 == Map.get(reviewed, :reviewer_config_sha256),
         response <-
           state.draft_response
           |> Map.delete(:fanout_worker)
           |> Map.put(:message, normalized.final_answer),
         {:ok, receipt} <-
           QualityReceipt.build(%{
             objective_id: state.objective_id,
             step_id: state.step_id,
             task_contract_sha256: state.task_contract_sha256,
             rule_catalog_version: 1,
             reviewer_config_sha256: reviewer_config_sha256,
             provider_call_count: 2,
             verdict: normalized.verdict,
             failed_rule_ids: normalized.failed_rule_ids,
             final_answer: normalized.final_answer
           }) do
      {:ok,
       Map.merge(state, %{
         status: :accepted,
         provider_call_count: 2,
         draft_response: nil,
         error: nil,
         final_answer: normalized.final_answer,
         quality_receipt: receipt,
         last_command: :review_and_revise,
         last_result: {:ok, %{response: response, quality_receipt: receipt}}
       })}
    else
      _invalid -> {:ok, unresolved(state, :invalid_or_unresolved_quality_review, 2)}
    end
  end

  defp normalize_reviewed(reviewed) when is_map(reviewed) do
    review = %{
      "final_answer" => Map.get(reviewed, :final_answer),
      "verdict" => Map.get(reviewed, :verdict),
      "rule_results" => Map.get(reviewed, :rule_results)
    }

    QualityPolicy.validate_review(review)
  end

  defp normalize_reviewed(_reviewed), do: {:error, :invalid_quality_review}

  defp valid_transition(%{
         status: :draft,
         provider_call_count: 1,
         objective_id: objective_id,
         step_id: step_id,
         task_contract: contract,
         task_contract_sha256: digest,
         draft_response: %{message: draft, direct_answer: %{source: :model}}
       })
       when is_binary(objective_id) and is_binary(step_id) and is_map(contract) and
              is_binary(digest) and is_binary(draft),
       do: :ok

  defp valid_transition(_state), do: {:error, :invalid_quality_review_transition}

  defp unresolved(state, reason, provider_call_count) do
    Map.merge(state, %{
      status: :unresolved,
      provider_call_count: provider_call_count,
      error: reason,
      last_command: :review_and_revise,
      last_result: {:error, reason}
    })
  end

  defp safe_prepare(reviewer, state, runner_context) do
    reviewer.prepare(state.task_contract, state.draft_response.message, runner_context)
  rescue
    exception -> {:error, exception.__struct__}
  catch
    :exit, reason -> {:error, reason}
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_invoke(reviewer, prepared, runner_context) do
    reviewer.invoke(prepared, runner_context)
  rescue
    exception -> {:error, exception.__struct__}
  catch
    :exit, reason -> {:error, reason}
    kind, reason -> {:error, {kind, reason}}
  end
end
