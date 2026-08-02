defmodule AllbertAssist.Objectives.Fanout.CriticAgent.Commands.Assess do
  @moduledoc false

  use Jido.Action,
    name: "allbert_fanout_private_critic_assess",
    description: "Invoke and validate one private policy-group critic."

  alias AllbertAssist.Objectives.Fanout.ReviewProtocol

  @impl true
  def run(
        %{
          protocol: %ReviewProtocol{} = protocol,
          group_id: group_id,
          source_bindings: source_bindings,
          request: request,
          critic_context: critic_context,
          implementation: implementation
        },
        context
      )
      when is_binary(group_id) and is_map(source_bindings) and is_map(request) and
             is_map(critic_context) and is_atom(implementation) do
    result =
      with true <- function_exported?(implementation, :assess, 2),
           {:ok, raw_assessment} <- implementation.assess(request, critic_context),
           {:ok, assessment} <-
             ReviewProtocol.validate_group_assessment(
               protocol,
               group_id,
               raw_assessment,
               source_bindings
             ) do
        {:ok, assessment}
      else
        false -> {:error, :invalid_critic_implementation}
        {:error, :invalid_critic_assessment} -> {:error, :invalid_critic_assessment}
        {:error, _reason} -> {:error, :critic_implementation_failed}
        _invalid -> {:error, :invalid_critic_assessment}
      end

    {:ok, terminal_state(Map.get(context, :state, %{}), result)}
  end

  def run(_params, context),
    do: {:ok, terminal_state(Map.get(context, :state, %{}), {:error, :invalid_critic_input})}

  defp terminal_state(state, {:ok, assessment}) do
    Map.merge(state, %{status: :assessed, assessment: assessment, error: nil})
  end

  defp terminal_state(state, {:error, reason}) do
    Map.merge(state, %{status: :failed, assessment: nil, error: reason})
  end
end
