defmodule StockSage.ObjectiveRuntimeTest do
  use StockSage.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Engine.Agent, as: EngineAgent
  alias AllbertAssist.Objectives.Proposer
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias Jido.Signal.Bus
  alias StockSage.Analyses
  alias StockSage.TraderBridge

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "stocksage-objective-runtime-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))

    put_setting!("stocksage.bridge_enabled", true)
    put_setting!("permissions.stocksage_analyze", "needs_confirmation")

    PluginRegistry.register_module(StockSage.Plugin)
    AppRegistry.register(StockSage.App)
    Proposer.register_app_proposer(:stocksage, StockSage.Proposer)

    case Process.whereis(StockSage.TraderBridge) do
      nil ->
        {:ok, pid} = TraderBridge.start_link(name: StockSage.TraderBridge)
        on_exit(fn -> safe_stop(pid) end)

      _pid ->
        :ok
    end

    on_exit(fn ->
      Proposer.unregister_app_proposer(:stocksage)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "single-step StockSage objective authorizes, resumes, executes, and observes" do
    trace_id = "trace_objective_runtime"
    name = start_test_engine()

    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.objective.**")

    assert {:ok, %{objective: objective}} =
             EngineAgent.frame_objective(name, %{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one StockSage analysis for AAPL.",
               source_intent: "analyze AAPL",
               active_app: :stocksage,
               acceptance_criteria: %{
                 "min_completed_steps" => 1,
                 "required" => [
                   %{
                     "kind" => "step_completed_with_action",
                     "action" => "StockSage.Actions.RunAnalysis",
                     "params_match" => %{"ticker" => "AAPL"},
                     "min_count" => 1
                   }
                 ],
                 "needs_more_when" => [
                   %{"kind" => "completed_step_count_below", "value" => 1}
                 ]
               }
             })

    assert {:ok, %{steps: [step]}} =
             EngineAgent.propose_steps(name, %{
               objective_id: objective.id,
               text: "analyze AAPL",
               force_stub: true
             })

    assert {:ok, %{step: blocked_step, response: authorize_response}} =
             EngineAgent.authorize_step(name, %{step_id: step.id, trace_id: trace_id})

    assert authorize_response.status == :needs_confirmation
    assert blocked_step.status == "blocked"
    assert blocked_step.confirmation_id == authorize_response.confirmation_id

    {:ok, confirmation} = Confirmations.read(authorize_response.confirmation_id)
    assert confirmation["objective_id"] == objective.id
    assert confirmation["step_id"] == step.id
    assert confirmation["params_summary"]["objective_title"] == "Analyze AAPL"
    assert confirmation["params_summary"]["objective_status"] == "running"

    assert {:ok, approval} =
             Runner.run(
               "approve_confirmation",
               %{id: authorize_response.confirmation_id, reason: "objective runtime test"},
               %{actor: "alice", channel: :test, surface: "objective-runtime"}
             )

    assert approval.status == :completed

    assert {:ok, %{step: completed_step}} =
             EngineAgent.execute_step(name, %{step_id: step.id, trace_id: trace_id})

    assert completed_step.status == "completed"

    assert {:ok, %{objective: completed_objective, verdict: :met}} =
             EngineAgent.observe_step(name, %{step_id: step.id, trace_id: trace_id})

    assert completed_objective.status == "completed"
    assert completed_objective.loop_count == 1

    assert [analysis] = Analyses.list_analyses("alice", limit: 10)
    assert analysis.objective_id == objective.id
    assert analysis.step_id == step.id
    assert analysis.status == "completed"

    kinds =
      objective.id
      |> Objectives.list_events(limit: 20)
      |> Enum.map(& &1.kind)

    assert "step_selected" in kinds
    assert "blocked" in kinds
    assert "step_completed" in kinds
    assert "observed" in kinds
    assert "completed" in kinds

    signals = drain_objective_signals([])
    assert Enum.any?(signals, &(&1.type == "allbert.objective.step.selected"))
    assert Enum.any?(signals, &(&1.type == "allbert.objective.blocked"))
    assert Enum.any?(signals, &(&1.type == "allbert.objective.step.completed"))
    assert Enum.any?(signals, &(&1.type == "allbert.objective.observed"))

    assert Enum.any?(signals, fn signal ->
             signal.type == "allbert.objective.completed" and signal.data.trace_id == trace_id
           end)
  end

  test "two-step StockSage objective continues from first approval to second confirmation and completion" do
    assert {:ok, %{objective: objective}} =
             EngineAgent.frame_objective(%{
               user_id: "alice",
               title: "Compare AAPL and MSFT",
               objective: "Complete StockSage analyses for AAPL and MSFT.",
               source_intent: "analyze AAPL and compare to MSFT",
               active_app: :stocksage,
               acceptance_criteria: %{
                 "min_completed_steps" => 2,
                 "required" => [
                   %{
                     "kind" => "step_completed_with_action",
                     "action" => "StockSage.Actions.RunAnalysis",
                     "params_match" => %{"ticker" => "AAPL"},
                     "min_count" => 1
                   },
                   %{
                     "kind" => "step_completed_with_action",
                     "action" => "StockSage.Actions.RunAnalysis",
                     "params_match" => %{"ticker" => "MSFT"},
                     "min_count" => 1
                   }
                 ],
                 "needs_more_when" => [
                   %{"kind" => "completed_step_count_below", "value" => 2}
                 ]
               }
             })

    assert {:ok, %{steps: [first]}} =
             EngineAgent.propose_steps(%{
               objective_id: objective.id,
               text: "analyze AAPL and compare to MSFT",
               force_stub: true
             })

    assert {:ok, %{step: first_blocked, response: first_authorize}} =
             EngineAgent.authorize_step(%{step_id: first.id, trace_id: "trace_compare_1"})

    assert first_blocked.status == "blocked"
    assert first_authorize.status == :needs_confirmation

    assert {:ok, _approval} =
             Runner.run(
               "approve_confirmation",
               %{id: first_authorize.confirmation_id, reason: "first compare step"},
               %{actor: "alice", user_id: "alice", channel: :test, trace_id: "trace_compare_1"}
             )

    assert {:ok, continue_one} =
             Runner.run(
               "continue_objective",
               %{id: objective.id, user_id: "alice"},
               %{actor: "alice", user_id: "alice", channel: :test, trace_id: "trace_compare_2"}
             )

    assert continue_one.status == :needs_confirmation
    assert is_binary(continue_one.confirmation_id)

    all_steps = Objectives.list_steps(objective.id)
    action_steps = Enum.filter(all_steps, &(&1.kind == "action"))
    delegate_steps = Enum.filter(all_steps, &(&1.kind == "delegate_agent"))

    [first_after, second] = action_steps
    assert first_after.status == "completed"
    assert second.status == "blocked"
    assert second.parent_step_id == first.id
    assert second.action_params |> Jason.decode!() |> Map.fetch!("ticker") == "MSFT"
    assert second.action_params |> Jason.decode!() |> Map.fetch!("force_stub") == true
    assert delegate_steps != []

    assert {:ok, _approval} =
             Runner.run(
               "approve_confirmation",
               %{id: continue_one.confirmation_id, reason: "second compare step"},
               %{actor: "alice", user_id: "alice", channel: :test, trace_id: "trace_compare_2"}
             )

    assert {:ok, continue_two} =
             Runner.run(
               "continue_objective",
               %{id: objective.id, user_id: "alice"},
               %{actor: "alice", user_id: "alice", channel: :test, trace_id: "trace_compare_3"}
             )

    assert continue_two.status == :completed

    {:ok, completed} = Objectives.get_objective(objective.id)
    assert completed.status == "completed"
    assert completed.loop_count == 2
    assert completed.proposer_hint == nil

    analyses = Analyses.list_analyses("alice", limit: 10)
    assert Enum.count(analyses, &(&1.objective_id == objective.id)) == 2
  end

  test "continue_objective is advisory when confirmation is still pending" do
    assert {:ok, %{objective: objective}} =
             EngineAgent.frame_objective(%{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one analysis.",
               source_intent: "analyze AAPL",
               active_app: :stocksage
             })

    assert {:ok, %{steps: [step]}} =
             EngineAgent.propose_steps(%{
               objective_id: objective.id,
               text: "analyze AAPL",
               force_stub: true
             })

    assert {:ok, %{response: authorization}} =
             EngineAgent.authorize_step(%{step_id: step.id, trace_id: "trace_pending"})

    assert authorization.status == :needs_confirmation

    assert {:ok, response} =
             Runner.run(
               "continue_objective",
               %{id: objective.id, user_id: "alice"},
               %{actor: "alice", user_id: "alice", channel: :test}
             )

    assert response.status == :still_blocked
    assert response.reason =~ "still pending"

    {:ok, unchanged} = Objectives.get_objective(objective.id)
    assert unchanged.loop_count == 0
  end

  test "cancel-then-approve keeps single-shot action result but does not advance objective" do
    assert {:ok, %{objective: objective}} =
             EngineAgent.frame_objective(%{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one analysis.",
               source_intent: "analyze AAPL",
               active_app: :stocksage
             })

    assert {:ok, %{steps: [step]}} =
             EngineAgent.propose_steps(%{
               objective_id: objective.id,
               text: "analyze AAPL",
               force_stub: true
             })

    assert {:ok, %{step: blocked_step, response: authorize_response}} =
             EngineAgent.authorize_step(%{step_id: step.id, trace_id: "trace_cancel_approve"})

    assert blocked_step.status == "blocked"
    assert authorize_response.status == :needs_confirmation

    assert {:ok, cancel_response} =
             Runner.run(
               "cancel_objective",
               %{id: objective.id, user_id: "alice", reason: "operator cancelled"},
               %{actor: "alice", user_id: "alice", channel: :test, trace_id: "trace_cancel"}
             )

    assert cancel_response.status == :cancelled

    assert {:ok, _approval} =
             Runner.run(
               "approve_confirmation",
               %{id: authorize_response.confirmation_id, reason: "approve stale work"},
               %{
                 actor: "alice",
                 user_id: "alice",
                 channel: :test,
                 trace_id: "trace_cancel_approve"
               }
             )

    assert {:ok, cancelled} = Objectives.get_objective(objective.id)
    assert cancelled.status == "cancelled"
    assert cancelled.loop_count == 0

    assert [cancelled_step] = Objectives.list_steps(objective.id)
    assert cancelled_step.status == "cancelled"

    analyses = Analyses.list_analyses("alice", limit: 10)
    assert Enum.any?(analyses, &(&1.objective_id == objective.id and &1.symbol == "AAPL"))

    assert {:ok, record} = Confirmations.read(authorize_response.confirmation_id)
    assert record["status"] == "approved"

    assert get_in(record, ["operator_resolution", "target_result", "objective_id"]) ==
             objective.id
  end

  test "observe_step records max_loop_count impasse when evaluator still needs more steps" do
    put_setting!("objectives.max_loop_count", 1)

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Needs two steps",
               objective: "Complete two analyses.",
               proposer_hint: %{
                 "app_id" => "stocksage",
                 "state" => %{"remaining_tickers" => ["MSFT"], "completed_steps" => []}
               },
               acceptance_criteria: %{
                 "min_completed_steps" => 2,
                 "required" => [
                   %{
                     "kind" => "step_completed_with_action",
                     "action" => "StockSage.Actions.RunAnalysis",
                     "params_match" => %{"ticker" => "AAPL"},
                     "min_count" => 1
                   },
                   %{
                     "kind" => "step_completed_with_action",
                     "action" => "StockSage.Actions.RunAnalysis",
                     "params_match" => %{"ticker" => "MSFT"},
                     "min_count" => 1
                   }
                 ],
                 "needs_more_when" => [
                   %{"kind" => "completed_step_count_below", "value" => 2}
                 ]
               }
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "completed",
               stage: "execute_step",
               candidate_action: "StockSage.Actions.RunAnalysis",
               action_params: %{ticker: "AAPL"}
             })

    assert {:ok, %{objective: blocked, verdict: :needs_more_steps}} =
             EngineAgent.observe_step(%{step_id: step.id, trace_id: "trace_impasse_loop"})

    assert blocked.status == "blocked"
    assert blocked.loop_count == 1

    [event] = Enum.filter(Objectives.list_events(objective.id), &(&1.kind == "impasse"))
    payload = Jason.decode!(event.payload)
    assert payload["cap_hit"] == "max_loop_count"
    assert payload["would_have_continued_verdict"] == "needs_more_steps"
  end

  test "propose_steps records max_steps_per_turn impasse" do
    put_setting!("objectives.max_steps_per_turn", 1)
    Proposer.unregister_app_proposer(:stocksage)
    assert :ok = Proposer.register_app_proposer(:stocksage, TooManyStepsProposer)

    assert {:ok, %{objective: objective}} =
             EngineAgent.frame_objective(%{
               user_id: "alice",
               title: "Too many",
               objective: "Return too many steps.",
               active_app: :stocksage
             })

    assert {:ok, %{objective: blocked, steps: [], impasse: :max_steps_per_turn}} =
             EngineAgent.propose_steps(%{objective_id: objective.id, text: "too many"})

    assert blocked.status == "blocked"

    [event] = Enum.filter(Objectives.list_events(objective.id), &(&1.kind == "impasse"))
    payload = Jason.decode!(event.payload)
    assert payload["cap_hit"] == "max_steps_per_turn"
    assert payload["proposed_steps"] == 2
  end

  defp start_test_engine do
    name = :"stocksage_objective_engine_#{System.unique_integer([:positive])}"
    start_supervised!({EngineAgent, name: name, id: Atom.to_string(name), child_id: name})
    name
  end

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "test"}) do
      {:ok, _resolved} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
    end
  end

  defp drain_objective_signals(acc) do
    receive do
      {:signal, signal} -> drain_objective_signals([signal | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end

defmodule TooManyStepsProposer do
  @behaviour AllbertAssist.Objectives.ProposerBehaviour

  @impl true
  def propose(_intent_decision, _context) do
    {:ok,
     [
       %{
         kind: "action",
         status: "proposed",
         stage: "propose_steps",
         candidate_action: "StockSage.Actions.RunAnalysis",
         action_params: %{ticker: "AAPL"}
       },
       %{
         kind: "action",
         status: "proposed",
         stage: "propose_steps",
         candidate_action: "StockSage.Actions.RunAnalysis",
         action_params: %{ticker: "MSFT"}
       }
     ], :done}
  end
end
