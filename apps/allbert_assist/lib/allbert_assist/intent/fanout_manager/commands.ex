defmodule AllbertAssist.Intent.FanoutManager.Commands do
  @moduledoc """
  Private Jido commands for the ephemeral conversational fan-out manager.

  These commands execute caller-bounded qualified model invocations and record
  only their result in temporary Agent state. They are not registered Allbert
  actions and grant no planning, execution, or permission authority.
  """

  @spec transition(map(), atom(), (-> term())) :: {:ok, map()}
  def transition(context, phase, invoke) when is_map(context) and is_function(invoke, 0) do
    state = Map.get(context, :state, %{})

    {:ok,
     Map.merge(state, %{
       phase: phase,
       phases: Map.get(state, :phases, []) ++ [phase],
       last_result: invoke.()
     })}
  end
end

defmodule AllbertAssist.Intent.FanoutManager.Commands.Assess do
  @moduledoc """
  Private command for the manager's outer-request work-unit assessment.
  """

  use Jido.Action,
    name: "allbert_conversation_fanout_assess",
    description: "Assess one operator request into bounded advisory work units."

  alias AllbertAssist.Intent.FanoutManager.Commands

  @impl true
  def run(%{invoke: invoke}, context) when is_function(invoke, 0),
    do: Commands.transition(context, :assessed, invoke)

  def run(_params, context),
    do:
      {:ok,
       Map.merge(Map.get(context, :state, %{}), %{
         phase: :failed,
         last_result: {:error, :invalid_assess_command}
       })}
end

defmodule AllbertAssist.Intent.FanoutManager.Commands.Adjudicate do
  @moduledoc """
  Private command for rule-bound review of a multi-unit manager candidate.
  """

  use Jido.Action,
    name: "allbert_conversation_fanout_adjudicate",
    description: "Adjudicate candidate work units against Allbert fan-out policy."

  alias AllbertAssist.Intent.FanoutManager.Commands

  @impl true
  def run(%{invoke: invoke}, context) when is_function(invoke, 0),
    do: Commands.transition(context, :adjudicated, invoke)

  def run(_params, context),
    do:
      {:ok,
       Map.merge(Map.get(context, :state, %{}), %{
         phase: :failed,
         last_result: {:error, :invalid_adjudicate_command}
       })}
end
