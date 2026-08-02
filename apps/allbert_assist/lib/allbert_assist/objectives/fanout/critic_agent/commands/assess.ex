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
      with :ok <- ensure_implementation(implementation),
           {:ok, implementation_result} <-
             invoke_implementation(implementation, request, critic_context),
           {:ok, raw_assessment, reviewer_config_sha256} <-
             validate_implementation_result(implementation_result),
           {:ok, assessment} <-
             ReviewProtocol.validate_group_assessment(
               protocol,
               group_id,
               raw_assessment,
               source_bindings
             ) do
        {:ok,
         %{
           assessment: assessment,
           reviewer_config_sha256: reviewer_config_sha256
         }}
      else
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _invalid -> {:error, :invalid_critic_result}
      end

    {:ok, terminal_state(Map.get(context, :state, %{}), result)}
  end

  def run(_params, context),
    do: {:ok, terminal_state(Map.get(context, :state, %{}), {:error, :invalid_critic_input})}

  defp terminal_state(
         state,
         {:ok,
          %{
            assessment: assessment,
            reviewer_config_sha256: reviewer_config_sha256
          }}
       ) do
    Map.merge(state, %{
      status: :assessed,
      assessment: assessment,
      reviewer_config_sha256: reviewer_config_sha256,
      error: nil
    })
  end

  defp terminal_state(state, {:error, reason}) do
    Map.merge(state, %{
      status: :failed,
      assessment: nil,
      reviewer_config_sha256: nil,
      error: reason
    })
  end

  defp ensure_implementation(implementation) do
    if function_exported?(implementation, :assess, 2),
      do: :ok,
      else: {:error, :invalid_critic_implementation}
  end

  defp invoke_implementation(implementation, request, critic_context) do
    case implementation.assess(request, critic_context) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> {:error, :critic_implementation_failed}
      _invalid -> {:error, :invalid_critic_result}
    end
  end

  defp validate_implementation_result(
         %{
           assessment: assessment,
           reviewer_config_sha256: reviewer_config_sha256
         } = result
       )
       when map_size(result) == 2 and is_map(assessment) do
    if sha256?(reviewer_config_sha256),
      do: {:ok, assessment, reviewer_config_sha256},
      else: {:error, :invalid_critic_result}
  end

  defp validate_implementation_result(_result), do: {:error, :invalid_critic_result}

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :lower) do
      {:ok, decoded} -> byte_size(decoded) == 32
      :error -> false
    end
  end

  defp sha256?(_value), do: false
end
