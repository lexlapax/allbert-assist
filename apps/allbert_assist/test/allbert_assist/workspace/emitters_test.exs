defmodule AllbertAssist.Workspace.EmittersTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Intent.Handoff
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace
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
    AllbertAssist.StockSageRegistryCase.setup()
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

  test "intent proposal surface ids are scoped by thread" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    handoff =
      Handoff.new!(%{
        kind: :app_handoff,
        app_id: :stocksage,
        action_name: "queue_analysis",
        label: "Queue StockSage analysis",
        source_text: "queue analysis for AAPL",
        extracted_slots: %{symbol: "AAPL"}
      })

    assert :ok = Emitters.intent_proposal(handoff, %{user_id: "alice", thread_id: "thr_one"})
    assert :ok = Emitters.intent_proposal(handoff, %{user_id: "alice", thread_id: "thr_two"})

    [first, second] = 2 |> collect_fragment_signals() |> Enum.map(& &1.data.envelope)

    assert first.id != second.id
    assert String.starts_with?(first.id, handoff.surface_id <> "_")
    assert String.starts_with?(second.id, handoff.surface_id <> "_")
    assert first.metadata.source_surface_id == handoff.surface_id
    assert second.metadata.source_surface_id == handoff.surface_id

    assert {:ok, [first_surface]} = Workspace.ephemeral_surfaces("thr_one", "alice")
    assert {:ok, [second_surface]} = Workspace.ephemeral_surfaces("thr_two", "alice")
    assert first_surface.id == first.id
    assert second_surface.id == second.id

    [_card, accept, decline] = first.surface.nodes
    assert accept.props.surface_id == first.id
    assert decline.props.surface_id == first.id
  end

  test "intent proposal uses lighter wording when already viewing the same app" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    handoff =
      Handoff.new!(%{
        kind: :app_handoff,
        app_id: :stocksage,
        action_name: "run_analysis",
        label: "Run StockSage analysis",
        source_text: "analyze CIEN",
        extracted_slots: %{ticker: "CIEN"}
      })

    assert :ok =
             Emitters.intent_proposal(handoff, %{
               user_id: "alice",
               thread_id: "thr_same_app",
               canvas_destination: "app:stocksage"
             })

    envelope = receive_signal("allbert.workspace.fragment.emitted").data.envelope
    [card | _buttons] = envelope.surface.nodes

    assert card.props.body =~ "Run StockSage analysis for CIEN?"
    refute card.props.body =~ "hand this to StockSage"
  end

  test "StockSage completion emits durable analysis and native progress canvas tiles" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    payload = %{
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
    }

    assert :ok = Emitters.stocksage_signal("allbert.stocksage.analysis_completed", payload)

    kinds =
      4
      |> collect_fragment_signals()
      |> Enum.map(& &1.data.envelope.kind)

    assert :analysis_card in kinds
    assert :agent_report_card in kinds
    assert :debate_round_card in kinds
    assert :parity_card in kinds

    assert {:ok, tiles} = Workspace.canvas_tiles("thr_stocksage", "alice")
    assert length(tiles) == 4

    tile_kinds = Enum.map(tiles, & &1.kind)
    assert "analysis_card" in tile_kinds
    assert "agent_report_card" in tile_kinds
    assert "debate_round_card" in tile_kinds
    assert "parity_card" in tile_kinds

    analysis_tile = Enum.find(tiles, &(&1.kind == "analysis_card"))
    assert analysis_tile.id == "stocksage_analysis_analysis_m22"
    assert analysis_tile.metadata["emitter_id"] == "StockSage.Actions.RunAnalysis"
    assert analysis_tile.metadata["scope"] == "canvas"
    assert is_binary(analysis_tile.metadata["emitted_at"])

    assert get_in(analysis_tile.body, ["fragment", "emitter_id"]) ==
             "StockSage.Actions.RunAnalysis"

    assert get_in(analysis_tile.body, ["surface", "app_id"]) == "stocksage"

    assert get_in(analysis_tile.body, ["surface", "nodes", Access.at(0), "component"]) ==
             "analysis_card"

    assert :ok = Emitters.stocksage_signal("allbert.stocksage.analysis_completed", payload)
    assert 4 |> collect_fragment_signals() |> length() == 4
    assert {:ok, tiles_after_reemit} = Workspace.canvas_tiles("thr_stocksage", "alice")
    assert length(tiles_after_reemit) == 4
  end

  test "StockSage failure emits visible analysis failure reason" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    reason = "native_llm_unavailable: provider credential missing for anthropic"

    assert :ok =
             Emitters.stocksage_signal("allbert.stocksage.analysis_failed", %{
               analysis_id: "analysis_failed_m22",
               ticker: "AAPL",
               analysis_date: "2026-05-18",
               engine: "native",
               user_id: "alice",
               thread_id: "thr_stocksage_failed",
               error: reason
             })

    signal = receive_signal("allbert.workspace.fragment.emitted")
    envelope = signal.data.envelope

    assert envelope.id == "stocksage_analysis_failed_analysis_failed_m22"
    assert envelope.scope == :canvas
    assert envelope.kind == :analysis_card
    assert envelope.thread_id == "thr_stocksage_failed"
    assert envelope.surface.fallback_text == reason

    [node] = envelope.surface.nodes
    assert node.props.body == reason
    assert node.props.status == "failed"
  end

  test "StockSage signals without workspace context do not emit durable tiles" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    assert :ok =
             Emitters.stocksage_signal("allbert.stocksage.analysis_completed", %{
               analysis_id: "analysis_no_thread",
               ticker: "AAPL",
               analysis_date: "2026-05-18",
               engine: "native",
               user_id: "alice"
             })

    refute_receive {:signal, %{type: "allbert.workspace.fragment.emitted"}}, 100
    assert {:ok, []} = Workspace.canvas_tiles("missing-thread", "alice")
  end

  defp confirmation_attrs do
    %{
      origin: %{
        actor: "alice",
        channel: :live_view,
        surface: "AllbertAssistWeb.WorkspaceLive",
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
