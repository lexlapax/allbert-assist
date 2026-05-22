defmodule StockSageWeb.LiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.{App, Confirmations, Objectives, Paths, Plugin, Session, Settings}
  alias StockSage.Analyses
  alias StockSage.Progress
  alias StockSage.Queue

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = Path.join(System.tmp_dir!(), "stocksage-live-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    ensure_stocksage_registered()
    _ = Session.clear_active_app("local", "web-local")

    on_exit(fn ->
      _ = Session.clear_active_app("local", "web-local")
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "StockSage routes mount and set the active app", %{conn: conn} do
    for {path, root_id} <- [
          {~p"/stocksage", "#stocksage-workspace"},
          {~p"/stocksage/analyses", "#stocksage-analyses"},
          {~p"/stocksage/analyses/ana_test", "#stocksage-analyses"},
          {~p"/stocksage/queue", "#stocksage-queue"},
          {~p"/stocksage/trends", "#stocksage-trends"}
        ] do
      {:ok, view, html} = live(conn, path)

      assert has_element?(view, root_id)
      assert has_element?(view, "#stocksage-nav")
      assert html =~ ~s(data-active-app="stocksage")
      assert html =~ "focus-visible:ring"
    end

    assert {:ok, %{active_app: :stocksage}} = Session.get("local", "web-local")
  end

  test "route surfaces agree with the provider metadata" do
    assert {:ok, attrs} = App.Validator.validate(StockSage.App)

    assert Enum.map(attrs.provider_surfaces, & &1.path) == [
             ~p"/stocksage",
             ~p"/stocksage/analyses",
             ~p"/stocksage/queue",
             ~p"/stocksage/trends"
           ]

    assert Enum.map(attrs.provider_surfaces, & &1.metadata.live_view) == [
             "StockSageWeb.WorkspaceLive",
             "StockSageWeb.AnalysisLive",
             "StockSageWeb.QueueLive",
             "StockSageWeb.TrendsLive"
           ]
  end

  test "disabled web setting leaves routes mounted with bounded disabled state", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("stocksage.web.enabled", false, %{audit?: false})

    {:ok, view, html} = live(conn, ~p"/stocksage")

    assert has_element?(view, "#stocksage-disabled")
    assert html =~ "StockSage web surfaces are disabled"
    assert {:ok, %{active_app: :stocksage}} = Session.get("local", "web-local")
  end

  test "workspace, queue, and trends render local app-flow state", %{conn: conn} do
    %{analysis: analysis} = create_analysis_detail_fixture()

    assert {:ok, queue_entry} =
             Queue.create_entry(%{
               user_id: "local",
               symbol: "MSFT",
               priority: "high",
               requested_for: ~D[2026-05-22]
             })

    assert {:ok, outcome} =
             Analyses.create_outcome(%{
               user_id: "local",
               symbol: "AAPL",
               label: "win",
               horizon_days: 30,
               observed_on: ~D[2026-05-22],
               return_pct: Decimal.new("4.2")
             })

    {:ok, workspace_view, workspace_html} = live(conn, ~p"/stocksage")
    assert has_element?(workspace_view, "#stocksage-workspace-summary")
    assert workspace_html =~ ~s(id="stocksage-workspace-analysis-#{analysis.id}")

    {:ok, queue_view, _queue_html} = live(conn, ~p"/stocksage/queue")
    assert has_element?(queue_view, "#stocksage-queue-entry-#{queue_entry.id}")
    assert render(queue_view) =~ "MSFT"

    {:ok, trends_view, _trends_html} = live(conn, ~p"/stocksage/trends")
    assert has_element?(trends_view, "#stocksage-trend-win")
    assert has_element?(trends_view, "#stocksage-outcome-#{outcome.id}")
    assert render(trends_view) =~ "4.2"
  end

  test "empty app-flow states render without data", %{conn: conn} do
    {:ok, analysis_view, _html} = live(conn, ~p"/stocksage/analyses")
    assert has_element?(analysis_view, "#stocksage-analysis-index-empty")

    {:ok, queue_view, _html} = live(conn, ~p"/stocksage/queue")
    assert has_element?(queue_view, "#stocksage-queue-empty")

    {:ok, trends_view, _html} = live(conn, ~p"/stocksage/trends")
    assert has_element?(trends_view, "#stocksage-trends-empty")
  end

  test "missing analysis renders bounded error state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/stocksage/analyses/ana_missing")

    assert has_element?(view, "#stocksage-analysis-error")
    assert html =~ "Analysis unavailable"
    assert html =~ "ana_missing"
  end

  test "analysis detail uses StockSage-owned card renderers", %{conn: conn} do
    %{analysis: analysis} = create_analysis_detail_fixture()

    {:ok, view, html} = live(conn, ~p"/stocksage/analyses/#{analysis.id}")

    assert has_element?(view, "#stocksage-analysis-surface-nodes")
    assert html =~ ~s(data-stocksage-component="analysis_card")
    assert html =~ "AAPL"
    refute html =~ "v0.26 stub"
  end

  test "analysis detail renders persisted cards, objective state, and confirmation links", %{
    conn: conn
  } do
    %{analysis: analysis, objective: objective, confirmation_id: confirmation_id} =
      create_analysis_detail_fixture()

    {:ok, view, html} = live(conn, ~p"/stocksage/analyses/#{analysis.id}")

    assert has_element?(view, "#stocksage-analysis-surface-nodes")
    assert html =~ ~s(data-stocksage-component="analysis_card")
    assert html =~ ~s(data-stocksage-component="agent_report_card")
    assert html =~ ~s(data-stocksage-component="debate_round_card")
    assert has_element?(view, "#stocksage-objective-state")
    assert has_element?(view, "#stocksage-objective-steps")
    assert has_element?(view, "#stocksage-cancel-objective")
    assert has_element?(view, "#stocksage-confirmation-links")
    assert html =~ objective.title
    assert html =~ confirmation_id
  end

  test "analysis detail catches up from persisted progress and appends live rows", %{conn: conn} do
    %{analysis: analysis} = create_analysis_detail_fixture()

    {:ok, view, html} = live(conn, ~p"/stocksage/analyses/#{analysis.id}")

    assert has_element?(view, "#stocksage-progress-stream")
    assert html =~ "Market context completed."
    assert html =~ "AAPL native analysis completed."

    Progress.broadcast("local", analysis.id, %{
      stage: "synthesis",
      status: "running",
      summary: "Synthesizing final decision."
    })

    assert render(view) =~ "Synthesizing final decision."
    assert has_element?(view, ~s(#stocksage-progress-stream [data-stage="synthesis"]))
  end

  defp ensure_stocksage_registered do
    plugin_registered? = match?({:ok, _entry}, Plugin.Registry.lookup("stocksage"))

    unless plugin_registered? do
      assert Plugin.Registry.register_module(StockSage.Plugin) in [
               {:ok, "stocksage"},
               {:error, {:plugin_id_taken, "stocksage"}}
             ]
    end

    unless App.Registry.known_app_id?(:stocksage) do
      assert {:ok, :stocksage} = App.Registry.register(StockSage.App)
    end
  end

  defp create_analysis_detail_fixture do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               source_thread_id: "thr_stocksage_live",
               session_id: "web-local",
               active_app: "stocksage",
               status: "running",
               title: "Analyze AAPL",
               objective: "Produce a StockSage analysis for AAPL.",
               source_intent: "stocksage.run_analysis"
             })

    assert {:ok, _step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: :delegate_agent,
               status: :completed,
               stage: :execute_step,
               provider: "stocksage.native",
               delegate_agent_id: "stocksage.market_context",
               result_summary: "Market context completed."
             })

    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "local",
               symbol: "AAPL",
               status: "completed",
               source: "native",
               engine: "native",
               recommendation: "Overweight",
               summary: "AAPL native analysis completed.",
               objective_id: objective.id,
               thread_id: "thr_stocksage_live",
               session_id: "web-local"
             })

    assert {:ok, _detail} =
             Analyses.create_detail(%{
               user_id: "local",
               analysis_id: analysis.id,
               section: "result",
               agent: "native_coordinator",
               content: "native detail",
               payload: %{
                 "native_report" => %{
                   "agent_reports" => %{
                     "stocksage.market_context" => %{
                       "role" => "analyst",
                       "status" => "completed",
                       "rating" => "Overweight",
                       "confidence" => 0.81,
                       "summary" => "Market context improved."
                     }
                   },
                   "debate_rounds" => [
                     %{
                       "round_index" => 1,
                       "bull" => %{
                         "status" => "completed",
                         "rating" => "Buy",
                         "summary" => "Bull case leads."
                       },
                       "bear" => %{
                         "status" => "completed",
                         "rating" => "Hold",
                         "summary" => "Bear case notes valuation."
                       }
                     }
                   ]
                 }
               }
             })

    confirmation_id = "conf_stocksage_live_#{System.unique_integer([:positive])}"

    assert {:ok, _confirmation} =
             Confirmations.create(%{
               id: confirmation_id,
               origin: %{actor: "local", channel: :live_view, surface: "/stocksage"},
               target_action: %{name: "run_analysis"},
               target_permission: :stocksage_analyze,
               target_execution_mode: :native_agent_graph,
               security_decision: %{
                 permission: :stocksage_analyze,
                 decision: :needs_confirmation
               },
               params_summary: %{objective_id: objective.id, ticker: "AAPL"}
             })

    %{analysis: analysis, objective: objective, confirmation_id: confirmation_id}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
