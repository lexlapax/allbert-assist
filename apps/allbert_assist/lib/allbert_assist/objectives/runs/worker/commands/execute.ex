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
  alias AllbertAssist.Objectives.Runs.CancelToken
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
    Map.merge(state, %{
      status: :draft,
      provider_call_count: 1,
      draft_response: Map.delete(response, :fanout_worker),
      last_command: :execute,
      last_result: {:ok, :draft}
    })
  end

  defp quality_state(state, {:ok, response}) when is_map(response) do
    provider_call_count =
      case Map.get(response, :fanout_worker) do
        %{version: 1, provider_call_count: count} when count in [0, 1] -> count
        _missing_or_invalid -> 0
      end

    quality_unresolved(state, :quality_model_draft_unavailable, provider_call_count)
  end

  defp quality_state(state, {:error, reason}),
    do: quality_unresolved(state, {:quality_draft_failed, reason}, 0)

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
