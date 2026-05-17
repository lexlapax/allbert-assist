defmodule AllbertAssist.Objectives.Engine.AgentTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.JidoBacked
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Engine.Agent, as: EngineAgent
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Proposer
  alias AllbertAssist.Repo
  alias Jido.AgentServer
  alias Jido.Signal.Bus

  test "private engine command modules are not registered capability actions" do
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

  test "no-op command returns a non-error dispatch for directive-free stub commands" do
    name = start_test_engine()

    assert {:ok, %{status: :noop}} =
             JidoBacked.dispatch(
               name,
               "allbert.objectives.engine.advance_objective",
               %{command: "advance_objective"},
               source: "/test"
             )
  end

  defp start_test_engine do
    name = :"objectives_engine_#{System.unique_integer([:positive])}"
    start_supervised!({EngineAgent, name: name, id: Atom.to_string(name), child_id: name})
    name
  end
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
