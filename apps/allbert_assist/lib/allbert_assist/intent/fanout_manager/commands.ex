defmodule AllbertAssist.Intent.FanoutManager.Commands do
  @moduledoc """
  Private Jido commands for the ephemeral conversational fan-out manager.

  `Assess` owns the bounded provider-call transition. `Adjudicate` owns the
  model-off deterministic policy/compiler transition. Together they validate
  the one-call-plus-optional-repair lifecycle in temporary Agent state. They are
  not registered Allbert actions and grant no planning, execution, or permission
  authority.
  """

  @spec assess(map(), (-> term())) :: {:ok, map()} | {:error, atom()}
  def assess(context, invoke) when is_map(context) and is_function(invoke, 0) do
    state = Map.get(context, :state, %{})

    if valid_assessment_transition?(state) do
      result = invoke.()

      {:ok,
       Map.merge(state, %{
         phase: :assessed,
         phases: Map.get(state, :phases, []) ++ [:assessed],
         attempts: Map.get(state, :attempts, 0) + 1,
         last_result: result
       })}
    else
      {:error, :invalid_fanout_assessment_transition}
    end
  end

  @spec adjudicate(map(), (-> term())) :: {:ok, map()} | {:error, atom()}
  def adjudicate(context, invoke) when is_map(context) and is_function(invoke, 0) do
    state = Map.get(context, :state, %{})

    if state[:phase] == :assessed and match?({:ok, _response}, state[:last_result]) do
      result = invoke.()

      {:ok,
       Map.merge(state, %{
         phase: :adjudicated,
         phases: Map.get(state, :phases, []) ++ [:adjudicated],
         last_result: result
       })}
    else
      {:error, :invalid_fanout_adjudication_transition}
    end
  end

  defp valid_assessment_transition?(%{phase: :ready, attempts: 0}), do: true

  defp valid_assessment_transition?(%{
         phase: :adjudicated,
         attempts: 1,
         last_result: {:error, _reason}
       }),
       do: true

  defp valid_assessment_transition?(_state), do: false
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
    do: Commands.assess(context, invoke)

  def run(_params, _context), do: {:error, :invalid_assess_command}
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
    do: Commands.adjudicate(context, invoke)

  def run(_params, _context), do: {:error, :invalid_adjudicate_command}
end
