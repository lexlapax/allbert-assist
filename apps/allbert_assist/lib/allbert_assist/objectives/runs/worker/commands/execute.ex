defmodule AllbertAssist.Objectives.Runs.Worker.Commands.Execute do
  @moduledoc """
  Private Jido command for one DirectAnswer worker turn.

  This module is not a registered Allbert capability action. It accepts only
  the canonical DirectAnswer module selected by the Worker Interface, then
  delegates to `Actions.Runner` so model resolution, disclosure, Active
  Memory, prompt policy, redaction, and failure handling stay centralized.
  """

  use Jido.Action,
    name: "allbert_objective_direct_answer_worker_execute",
    description: "Delegate one validated DirectAnswer child to the Allbert Runner."

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives.ObservationSummary
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Objectives.Runs.Worker.QualityReceipt
  alias AllbertAssist.Settings.Store

  @impl true
  def run(
        %{
          action_module: DirectAnswer,
          action_params: action_params,
          runner_context: runner_context
        },
        context
      )
      when is_map(action_params) and is_map(runner_context) do
    result =
      case CancelToken.checkpoint(runner_context) do
        :ok ->
          Store.with_resolved_settings(fn ->
            Runner.run(DirectAnswer, action_params, runner_context)
          end)

        :cancelled ->
          {:error, :cancelled}
      end

    {:ok, next_state(context, result)}
  end

  def run(_params, context), do: {:ok, next_state(context, {:error, :invalid_worker_input})}

  defp next_state(%{state: %{task_contract: %{} = _contract} = state}, result),
    do: quality_state(state, result)

  defp next_state(context, result), do: terminal_state(context, result)

  defp quality_state(
         state,
         {:ok,
          %{
            direct_answer: %{source: :model},
            fanout_worker: %{version: 1, provider_call_count: 1}
          } = response}
       ) do
    # v1.3 M9.b.6 (ADR 0021 A24): one generation terminalizes the child. There is
    # no draft/critic/revision continuation, so the receipt is minted here.
    with {:ok, response} <- normalized_response(response),
         {:ok, receipt} <- accepted_receipt(state, response) do
      Map.merge(state, %{
        status: :accepted,
        provider_call_count: 1,
        last_command: :execute,
        last_result:
          {:ok, %{response: Map.delete(response, :fanout_worker), quality_receipt: receipt}}
      })
    else
      {:error, reason} -> quality_unresolved(state, reason, 1)
    end
  end

  defp quality_state(state, {:ok, response}) when is_map(response) do
    case Map.get(response, :fanout_worker) do
      %{version: 1, provider_call_count: count} when count in [0, 1] ->
        quality_unresolved(state, :quality_model_draft_unavailable, count)

      %{version: 1, provider_call_count: count} when is_integer(count) and count > 1 ->
        quality_unresolved(state, :quality_provider_attempt_bound_exceeded, count)

      _missing_or_invalid ->
        quality_unresolved(state, :quality_model_draft_unavailable, 0)
    end
  end

  defp quality_state(state, {:error, reason}),
    do: quality_unresolved(state, {:quality_draft_failed, reason}, 0)

  defp accepted_receipt(state, response) do
    binding = %{
      "objective_id" => Map.get(state, :objective_id),
      "step_id" => Map.get(state, :step_id),
      "task_contract_sha256" => Map.get(state, :task_contract_sha256),
      "instructed_rule_catalog_version" => 2,
      "generator_config_sha256" => generator_config_sha256(response),
      "generation_call_count" => 1,
      "provider_call_count" => 1,
      "outcome" => "generated",
      "final_answer" => Map.get(response, :message)
    }

    case QualityReceipt.build(binding) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, _reason} -> {:error, :quality_receipt_unavailable}
    end
  end

  defp generator_config_sha256(response) do
    case get_in(response, [:fanout_worker, :configuration_sha256]) do
      digest when is_binary(digest) -> digest
      _missing -> sha256(inspect(Map.get(response, :direct_answer)))
    end
  end

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp normalized_response(%{message: message} = response) when is_binary(message) do
    normalized = ObservationSummary.normalize(message)

    if String.trim(normalized) == "",
      do: {:error, :quality_model_draft_unavailable},
      else: {:ok, Map.put(response, :message, normalized)}
  end

  defp normalized_response(_response), do: {:error, :quality_model_draft_unavailable}

  defp quality_unresolved(state, reason, provider_call_count) do
    Map.merge(state, %{
      status: :unresolved,
      provider_call_count: provider_call_count,
      error: reason,
      last_command: :execute,
      last_result: {:error, reason}
    })
  end

  defp terminal_state(context, {:ok, response} = result) do
    context
    |> Map.get(:state, %{})
    |> Map.merge(%{
      status: :completed,
      last_answer: response,
      last_command: :execute,
      last_result: result
    })
  end

  defp terminal_state(context, {:error, reason} = result) do
    context
    |> Map.get(:state, %{})
    |> Map.merge(%{
      status: :failed,
      error: reason,
      last_command: :execute,
      last_result: result
    })
  end
end
