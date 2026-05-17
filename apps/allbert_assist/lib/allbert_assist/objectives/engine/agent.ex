defmodule AllbertAssist.Objectives.Engine.Agent do
  @moduledoc """
  JidoBacked coordinator for the v0.24 objective runtime.

  SQLite objective tables are authoritative. This process keeps only a
  rebuildable projection and routes private engine commands through Jido
  signal routes.
  """

  alias AllbertAssist.JidoBacked
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias AllbertAssist.Objectives.Proposer

  @frame_objective "allbert.objectives.engine.frame_objective"
  @propose_steps "allbert.objectives.engine.propose_steps"
  @evaluate_steps "allbert.objectives.engine.evaluate_steps"
  @authorize_step "allbert.objectives.engine.authorize_step"
  @execute_step "allbert.objectives.engine.execute_step"
  @observe_step "allbert.objectives.engine.observe_step"
  @advance_objective "allbert.objectives.engine.advance_objective"
  @cancel_objective "allbert.objectives.engine.cancel_objective"
  @continue_objective "allbert.objectives.engine.continue_objective"
  @prune_stale "allbert.objectives.engine.prune_stale"

  use JidoBacked,
    name: "allbert_objectives_engine",
    description: "Coordinates durable objective lifecycle stages.",
    schema: [
      active_objectives: [type: :map, default: %{}],
      current_stage: [type: :map, default: %{}],
      loop_counts: [type: :map, default: %{}],
      last_acceptance_verdicts: [type: :map, default: %{}],
      proposer_hints: [type: :map, default: %{}],
      last_rebuilt_at: [type: :string, default: nil],
      last_command: [type: :atom, default: nil],
      last_result: [type: :any, default: nil],
      last_error: [type: :string, default: nil],
      last_summary: [type: :any, default: nil]
    ],
    signal_routes: [
      {@frame_objective, Commands.FrameObjective},
      {@propose_steps, Commands.ProposeSteps},
      {@evaluate_steps, Commands.Noop},
      {@authorize_step, Commands.AuthorizeStep},
      {@execute_step, Commands.ExecuteStep},
      {@observe_step, Commands.ObserveStep},
      {@advance_objective, Commands.Noop},
      {@cancel_objective, Commands.CancelObjective},
      {@continue_objective, Commands.Noop},
      {@prune_stale, Commands.Noop}
    ]

  @doc false
  @impl true
  def rebuild_state(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    {:ok, abandoned} = Objectives.abandon_stale_objectives(now: now)
    active = Objectives.active_objectives(now: now)

    {:ok,
     %{
       active_objectives: Map.new(active, &{&1.id, Objectives.objective_summary(&1)}),
       current_stage: Map.new(active, &{&1.id, &1.status}),
       loop_counts: Map.new(active, &{&1.id, &1.loop_count || 0}),
       last_acceptance_verdicts: %{},
       proposer_hints: proposer_hints(active),
       last_rebuilt_at: now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
       last_command: :rebuild,
       last_result: {:ok, %{active: length(active), abandoned: abandoned}},
       last_error: nil,
       last_summary: %{active: length(active), abandoned: abandoned}
     }}
  end

  @doc false
  @impl true
  def command_modules do
    [
      Commands.FrameObjective,
      Commands.ProposeSteps,
      Commands.AuthorizeStep,
      Commands.ExecuteStep,
      Commands.ObserveStep,
      Commands.CancelObjective,
      Commands.Noop
    ]
  end

  @doc false
  def frame_objective(server \\ __MODULE__, params) when is_map(params) do
    dispatch(server, @frame_objective, params)
  end

  @doc false
  def propose_steps(server \\ __MODULE__, params) when is_map(params) do
    dispatch(server, @propose_steps, params)
  end

  @doc false
  def authorize_step(server \\ __MODULE__, params) when is_map(params) do
    dispatch(server, @authorize_step, Map.put(params, :command, :authorize_step))
  end

  @doc false
  def cancel_objective(server \\ __MODULE__, params) when is_map(params) do
    dispatch(server, @cancel_objective, Map.put(params, :command, :cancel_objective))
  end

  @doc false
  def continue_objective(server \\ __MODULE__, params) when is_map(params) do
    dispatch(server, @continue_objective, Map.put(params, :command, :continue_objective))
  end

  @doc false
  def execute_step(server \\ __MODULE__, params) when is_map(params) do
    dispatch(server, @execute_step, Map.put(params, :command, :execute_step))
  end

  @doc false
  def observe_step(server \\ __MODULE__, params) when is_map(params) do
    dispatch(server, @observe_step, Map.put(params, :command, :observe_step))
  end

  @doc false
  def handle_command_error(state, command, reason, attrs \\ %{}) do
    {:ok,
     Map.merge(
       %{
         last_command: command,
         last_result: {:error, reason},
         last_error: inspect(reason)
       },
       attrs
     )
     |> Map.merge(Map.take(state, [:active_objectives, :current_stage, :loop_counts]))}
  end

  defp dispatch(server, signal_type, params) do
    JidoBacked.dispatch(server, signal_type, params,
      source: "/allbert/objectives/engine",
      timeout: :infinity
    )
  end

  defp proposer_hints(active) do
    active
    |> Enum.flat_map(&proposer_hint_entry/1)
    |> Map.new()
  end

  defp proposer_hint_entry(%{id: id, proposer_hint: hint}) when is_binary(hint) do
    with {:ok, %{} = hint_map} <- Jason.decode(hint),
         {:ok, normalized_hint} when not is_nil(normalized_hint) <-
           Proposer.normalize_hint(hint_map) do
      [{id, normalized_hint}]
    else
      _other -> []
    end
  end

  defp proposer_hint_entry(_objective), do: []
end
