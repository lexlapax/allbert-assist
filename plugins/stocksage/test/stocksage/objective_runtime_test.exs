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
