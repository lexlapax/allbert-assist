defmodule AllbertAssist.Objectives.Engine.AgentTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Objectives.Engine.Agent, as: EngineAgent
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Proposer
  alias AllbertAssist.Repo
  alias Jido.AgentServer
  alias Jido.Signal.Bus

  test "private engine command modules are not registered capability actions" do
    assert EngineAgent.command_modules() == [
             AllbertAssist.Objectives.Commands.FrameObjective,
             AllbertAssist.Objectives.Commands.ProposeSteps,
             AllbertAssist.Objectives.Commands.EvaluateSteps,
             AllbertAssist.Objectives.Commands.AuthorizeStep,
             AllbertAssist.Objectives.Commands.ExecuteStep,
             AllbertAssist.Objectives.Commands.ObserveStep,
             AllbertAssist.Objectives.Commands.AdvanceObjective,
             AllbertAssist.Objectives.Commands.CancelObjective,
             AllbertAssist.Objectives.Commands.ContinueObjective,
             AllbertAssist.Objectives.Commands.PruneStale
           ]

    for module <- EngineAgent.command_modules() do
      refute Registry.registered_module?(module)
      assert {:error, {:unknown_action, ^module}} = Registry.capability(module)
    end
  end

  test "frame_objective dispatch creates a durable objective and emits an objective signal" do
    name = start_test_engine()

    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.objective.**")

    assert {:ok, %{objective: objective}} =
             EngineAgent.frame_objective(name, %{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               active_app: :stocksage
             })

    assert objective.user_id == "alice"
    assert objective.active_app == "stocksage"
    assert {:ok, loaded} = Objectives.get_objective(objective.id)
    assert loaded.title == "Analyze AAPL"

    assert_receive {:signal, signal}, 1_000
    assert signal.type == "allbert.objective.created"
    assert signal.data.objective_id == objective.id
    assert signal.data.user_id == "alice"

    assert {:ok, %{agent: %{state: state}}} = AgentServer.state(name)
    assert Map.has_key?(state.active_objectives, objective.id)
  end

  test "propose_steps persists steps and durable hybrid hints" do
    on_exit(fn -> Proposer.unregister_app_proposer(:allbert) end)
    assert :ok = Proposer.register_app_proposer(:allbert, HybridProposer)

    name = start_test_engine()

    assert {:ok, %{objective: objective}} =
             EngineAgent.frame_objective(name, %{
               user_id: "alice",
               title: "Compare AAPL and MSFT",
               objective: "Complete two analysis steps.",
               source_intent: "analyze AAPL and compare to MSFT",
               active_app: :allbert
             })

    assert {:ok, %{steps: [first], continuation: %{status: :more}}} =
             EngineAgent.propose_steps(name, %{
               objective_id: objective.id,
               text: "analyze AAPL and compare to MSFT"
             })

    assert first.candidate_action == "StockSage.Actions.RunAnalysis"
    assert first.action_params |> Jason.decode!() |> Map.fetch!("ticker") == "AAPL"

    assert {:ok, hinted} = Objectives.get_objective(objective.id)
    assert %{"app_id" => "allbert"} = Jason.decode!(hinted.proposer_hint)

    assert {:ok, %{steps: [second], continuation: %{status: :done}}} =
             EngineAgent.propose_steps(name, %{
               objective_id: objective.id,
               text: "continue objective"
             })

    assert second.action_params |> Jason.decode!() |> Map.fetch!("ticker") == "MSFT"
    assert [_, _] = Objectives.list_steps(objective.id)
    assert {:ok, done} = Objectives.get_objective(objective.id)
    assert done.proposer_hint == nil
  end

  test "handle_command_error records bounded error state without crashing" do
    state = %{
      active_objectives: %{"obj_1" => %{id: "obj_1"}},
      current_stage: %{},
      loop_counts: %{}
    }

    assert {:ok, patch} = EngineAgent.handle_command_error(state, :execute_step, :db_busy)

    assert patch.last_command == :execute_step
    assert patch.last_result == {:error, :db_busy}
    assert patch.last_error == ":db_busy"

    changeset = Objective.changeset(%Objective{}, %{})
    assert {:ok, patch} = EngineAgent.handle_command_error(state, :frame_objective, changeset)
    assert patch.last_error =~ "Ecto.Changeset"
  end

  test "rebuild_state eagerly rehydrates active objectives and abandons stale ones" do
    now = DateTime.utc_now()

    assert {:ok, open} =
             Objectives.create_objective(%{
               user_id: "alice",
               status: "open",
               title: "Open",
               objective: "Open objective"
             })

    assert {:ok, running} =
             Objectives.create_objective(%{
               user_id: "alice",
               status: "running",
               title: "Running",
               objective: "Running objective"
             })

    assert {:ok, completed} =
             Objectives.create_objective(%{
               user_id: "alice",
               status: "completed",
               title: "Completed",
               objective: "Completed objective"
             })

    assert {:ok, stale} =
             Objectives.create_objective(%{
               user_id: "alice",
               status: "blocked",
               title: "Stale",
               objective: "Stale objective"
             })

    stale_at = DateTime.add(now, -2, :hour)

    assert {1, _} =
             Objective
             |> where([objective], objective.id == ^stale.id)
             |> Repo.update_all(set: [updated_at: stale_at])

    assert {:ok, state} = EngineAgent.rebuild_state(now: now)

    assert Map.has_key?(state.active_objectives, open.id)
    assert Map.has_key?(state.active_objectives, running.id)
    refute Map.has_key?(state.active_objectives, completed.id)
    refute Map.has_key?(state.active_objectives, stale.id)
    assert state.last_summary.abandoned == 1

    assert {:ok, stale_after} = Objectives.get_objective(stale.id)
    assert stale_after.status == "abandoned"
  end

  test "supervisor restart reloads durable proposer hints from sqlite" do
    name = :"objectives_engine_restart_#{System.unique_integer([:positive])}"

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               status: "open",
               active_app: "allbert",
               title: "Restart with hint",
               objective: "Keep proposer hint durable.",
               proposer_hint: %{"app_id" => "allbert", "state" => %{"cursor" => 1}}
             })

    start_supervised!({EngineAgent, name: name, id: Atom.to_string(name), child_id: name})
    assert {:ok, %{agent: %{state: state}}} = AgentServer.state(name)
    assert state.proposer_hints[objective.id] == {:allbert, %{"cursor" => 1}}

    :ok = stop_supervised(name)

    start_supervised!({EngineAgent, name: name, id: Atom.to_string(name), child_id: name})
    assert {:ok, %{agent: %{state: restarted}}} = AgentServer.state(name)
    assert restarted.proposer_hints[objective.id] == {:allbert, %{"cursor" => 1}}
  end

  test "evaluate_steps records a deterministic acceptance verdict" do
    name = start_test_engine()

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Evaluate",
               objective: "Evaluate one completed step."
             })

    assert {:ok, _step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "completed",
               stage: "observe_step",
               candidate_action: "StockSage.Actions.RunAnalysis"
             })

    assert {:ok, %{verdict: :met, evaluated_steps: 1}} =
             EngineAgent.evaluate_steps(name, %{objective_id: objective.id})

    assert {:ok, %{agent: %{state: state}}} = AgentServer.state(name)
    assert state.last_acceptance_verdicts[objective.id] == :met
  end

  test "prune_stale command prunes and can return a conservative schedule directive" do
    now = DateTime.utc_now()
    name = start_test_engine()

    assert {:ok, stale} =
             Objectives.create_objective(%{
               user_id: "alice",
               status: "blocked",
               title: "Stale",
               objective: "Stale objective"
             })

    stale_at = DateTime.add(now, -2, :hour)

    assert {1, _} =
             Objective
             |> where([o], o.id == ^stale.id)
             |> Repo.update_all(set: [updated_at: stale_at])

    assert {:ok, %{status: :completed, abandoned: 1}} =
             EngineAgent.prune_stale(name, %{now: now, schedule_next_ms: 60_000})

    assert {:ok, pruned} = Objectives.get_objective(stale.id)
    assert pruned.status == "abandoned"
  end

  test "delegate_agent step executes through registered delegate action and AgentRegistry" do
    engine_name = start_test_engine()
    delegate_name = :"objective_delegate_#{System.unique_integer([:positive])}"
    start_supervised!({DelegateTestAgent, name: delegate_name})

    assert {:ok, _entry} =
             AgentRegistry.register("delegate-test", delegate_name, DelegateTestAgent, %{})

    on_exit(fn -> AgentRegistry.unregister("delegate-test") end)

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Delegate",
               objective: "Delegate one step."
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "delegate_agent",
               status: "selected",
               stage: "execute_step",
               delegate_agent_id: "delegate-test",
               action_params: %{payload: "hello"}
             })

    assert {:ok, %{step: completed, objective: completed_objective, verdict: :met}} =
             EngineAgent.advance_objective(engine_name, %{
               step_id: step.id,
               trace_id: "trace_delegate"
             })

    assert completed.status == "completed"
    assert completed.result_summary =~ "Delegated objective step"
    assert completed_objective.status == "completed"
  end

  test "delegate_agent step threads nested command and params through objective execution" do
    engine_name = start_test_engine()
    delegate_name = :"objective_delegate_research_#{System.unique_integer([:positive])}"
    start_supervised!({DelegateTestAgent, name: delegate_name})

    assert {:ok, _entry} =
             AgentRegistry.register("delegate-research", delegate_name, DelegateTestAgent, %{
               allowed_commands: [:research]
             })

    on_exit(fn -> AgentRegistry.unregister("delegate-research") end)

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Delegate research",
               objective: "Delegate one research step."
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "delegate_agent",
               status: "selected",
               stage: "execute_step",
               delegate_agent_id: "delegate-research",
               action_params: %{command: "research", params: %{payload: "topic"}}
             })

    assert {:ok, %{step: completed, objective: completed_objective, verdict: :met}} =
             EngineAgent.advance_objective(engine_name, %{
               step_id: step.id,
               trace_id: "trace_delegate_research"
             })

    assert completed.status == "completed"
    assert completed_objective.status == "completed"

    assert {:ok, %{agent: %{state: state}}} = AgentServer.state(delegate_name)
    assert state.last_command == :research
    assert state.last_result == {:ok, %{payload: %{payload: "topic"}, status: :completed}}
  end

  defp start_test_engine do
    name = :"objectives_engine_#{System.unique_integer([:positive])}"
    start_supervised!({EngineAgent, name: name, id: Atom.to_string(name), child_id: name})
    name
  end
end

defmodule DelegateTestCommand do
  use Jido.Action,
    name: "delegate_test_command",
    description: "Test-only delegate command."

  @impl true
  def run(params, _context) do
    {:ok,
     %{
       delegate_payload: params,
       last_result: {:ok, %{status: :completed}},
       last_summary: "delegate completed"
     }}
  end
end

defmodule DelegateTestResearchCommand do
  use Jido.Action,
    name: "delegate_test_research_command",
    description: "Test-only delegate research command."

  @impl true
  def run(params, _context) do
    {:ok,
     %{
       last_command: :research,
       last_result: {:ok, %{payload: params, status: :completed}},
       last_summary: "delegate research completed"
     }}
  end
end

defmodule DelegateTestAgent do
  use AllbertAssist.JidoBacked,
    name: "delegate_test_agent",
    description: "Test-only objective delegate agent.",
    signal_routes: [
      {"allbert.objectives.delegate.execute", DelegateTestCommand},
      {"allbert.objectives.delegate.research", DelegateTestResearchCommand}
    ]

  @impl true
  def rebuild_state(_opts), do: {:ok, %{last_result: {:ok, %{status: :idle}}}}

  @impl true
  def command_modules, do: [DelegateTestCommand, DelegateTestResearchCommand]
end

defmodule HybridProposer do
  @behaviour AllbertAssist.Objectives.ProposerBehaviour

  @impl true
  def propose(_intent_decision, %{proposer_hint: {:allbert, %{"cursor" => 1}}}) do
    {:ok, [step("MSFT")], :done}
  end

  def propose(_intent_decision, _context) do
    {:ok, [step("AAPL")], {:more, {:allbert, %{"cursor" => 1}}}}
  end

  defp step(ticker) do
    %{
      kind: "action",
      stage: "propose_steps",
      provider: inspect(__MODULE__),
      candidate_action: "StockSage.Actions.RunAnalysis",
      action_params: %{"ticker" => ticker}
    }
  end
end
