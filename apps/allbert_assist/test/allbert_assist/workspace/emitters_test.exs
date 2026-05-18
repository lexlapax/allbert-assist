defmodule AllbertAssist.Workspace.EmittersTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.Emitters
  alias AllbertAssist.Workspace.Fragment.Guard
  alias Jido.Signal.Bus

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-emitters-test-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Guard.reset_for_test()

    on_exit(fn ->
      Guard.reset_for_test()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf(home)
    end)

    :ok
  end

  test "confirmation creation emits a signed approval card fragment" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    assert {:ok, record} = Confirmations.create(confirmation_attrs())

    signal = receive_signal("allbert.workspace.fragment.emitted")
    envelope = signal.data.envelope

    assert envelope.id == "confirmation_#{record["id"]}"
    assert envelope.scope == :ephemeral
    assert envelope.kind == :approval_card
    assert envelope.user_id == "alice"
    assert envelope.thread_id == "thr_confirmation"
    assert is_binary(envelope.signature)
    assert envelope.metadata.confirmation_id == record["id"]

    [node] = envelope.surface.nodes
    assert node.component == :approval_card
    assert node.props.confirmation_id == record["id"]
    assert node.props.target_action == "run_analysis"
  end

  test "confirmation resolution emits a close lifecycle signal" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.ephemeral.closed")

    assert {:ok, record} = Confirmations.create(confirmation_attrs())
    assert {:ok, resolved} = Confirmations.resolve(record["id"], :denied)

    signal = receive_signal("allbert.workspace.ephemeral.closed")

    assert signal.data.surface_id == "confirmation_#{record["id"]}"
    assert signal.data.user_id == "alice"
    assert signal.data.thread_id == "thr_confirmation"
    assert signal.data.dismissed_by == :confirmation_resolved
    assert signal.data.metadata.status == resolved["status"]
  end

  test "objective lifecycle emits deterministic objective card fragments" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    objective = %Objective{
      id: "obj_workspace_emit",
      user_id: "alice",
      source_thread_id: "thr_objective",
      session_id: "sess_objective",
      active_app: "allbert",
      status: "running",
      title: "Ship v0.26",
      objective: "Prepare v0.26 for release."
    }

    assert :ok =
             Emitters.objective_lifecycle(:observed, objective, %{
               stage: :observe_step,
               observation_summary: "Evidence gathered."
             })

    signal = receive_signal("allbert.workspace.fragment.emitted")
    envelope = signal.data.envelope

    assert envelope.id == "objective_obj_workspace_emit"
    assert envelope.scope == :canvas
    assert envelope.kind == :objective_card
    assert envelope.metadata.objective_id == "obj_workspace_emit"

    [node] = envelope.surface.nodes
    assert node.component == :objective_card
    assert node.props.objective_id == "obj_workspace_emit"
    assert node.props.body == "Evidence gathered."
  end

  test "StockSage completion emits analysis and native progress card stubs" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    assert :ok =
             Emitters.stocksage_signal("allbert.stocksage.analysis_completed", %{
               analysis_id: "analysis_m22",
               ticker: "AAPL",
               analysis_date: "2026-05-18",
               engine: "both",
               user_id: "alice",
               thread_id: "thr_stocksage",
               native_trace: %{
                 "agent_reports" => [%{"agent_id" => "stocksage.market_context"}],
                 "debate_rounds" => [%{"round_index" => 1}],
                 "parity_diff" => %{"parity_pass" => true}
               }
             })

    kinds =
      4
      |> collect_fragment_signals()
      |> Enum.map(& &1.data.envelope.kind)

    assert :analysis_card in kinds
    assert :agent_report_card in kinds
    assert :debate_round_card in kinds
    assert :parity_card in kinds
  end

  defp confirmation_attrs do
    %{
      origin: %{
        actor: "alice",
        channel: :live_view,
        surface: "AllbertAssistWeb.AgentLive",
        user_id: "alice",
        thread_id: "thr_confirmation",
        session_id: "sess_confirmation"
      },
      target_action: %{name: "run_analysis", module: "StockSage.Actions.RunAnalysis"},
      target_permission: :stocksage_analyze,
      target_execution_mode: :native_agent_graph,
      security_decision: %{permission: :stocksage_analyze, decision: :needs_confirmation},
      params_summary: %{ticker: "AAPL", engine: "native"}
    }
  end

  defp receive_signal(type) do
    receive do
      {:signal, %{type: ^type} = signal} -> signal
      {:signal, _signal} -> receive_signal(type)
    after
      1_000 -> flunk("expected signal #{type}")
    end
  end

  defp collect_fragment_signals(count), do: collect_fragment_signals(count, [])

  defp collect_fragment_signals(count, acc) when length(acc) >= count, do: Enum.reverse(acc)

  defp collect_fragment_signals(count, acc) do
    receive do
      {:signal, %{type: "allbert.workspace.fragment.emitted"} = signal} ->
        collect_fragment_signals(count, [signal | acc])

      {:signal, _signal} ->
        collect_fragment_signals(count, acc)
    after
      1_000 -> Enum.reverse(acc)
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
