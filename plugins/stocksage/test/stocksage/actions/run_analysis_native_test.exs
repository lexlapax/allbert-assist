defmodule StockSage.Actions.RunAnalysisNativeTest do
  use StockSage.DataCase, async: false

  defmodule FakeLLMProvider do
    def generate_report(spec, request, _evidence, prior_reports, model_profile) do
      if pid = Application.get_env(:allbert_assist, :stocksage_llm_test_pid) do
        send(pid, {:stocksage_llm_called, spec.id, model_profile})
      end

      ticker = Map.get(request, :ticker, "UNKNOWN")

      extra =
        if spec.role == :decision_synthesizer do
          %{
            final_trade_decision: "Overweight",
            rating: "Overweight",
            recommendation: "Overweight",
            investment_plan: "Stage exposure and review evidence drift.",
            trader_investment_plan: "No autonomous order placement.",
            market_report: report_text(prior_reports, "stocksage.market_context"),
            sentiment_report: report_text(prior_reports, "stocksage.news_sentiment"),
            news_report: report_text(prior_reports, "stocksage.news_sentiment"),
            fundamentals_report: report_text(prior_reports, "stocksage.fundamentals")
          }
        else
          %{}
        end

      {:ok,
       %{
         summary: "#{spec.id} LLM report for #{ticker}.",
         report: "#{spec.id} used Jido.AI fake provider for #{ticker}.",
         confidence: 0.77,
         warnings: [],
         data_requests: [],
         generation_mode: "jido_ai_llm",
         extra: extra
       }}
    end

    defp report_text(reports, key) do
      reports
      |> Map.get(key, %{})
      |> Map.get(:report, "")
    end
  end

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Fragment.Guard
  alias Jido.Signal.Bus
  alias StockSage.Analyses
  alias StockSage.SurfaceNodes

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "stocksage-native-test-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Guard.reset_for_test()

    put_setting!("stocksage.native_engine_enabled", true)
    put_setting!("stocksage.native_llm_enabled", false)
    put_setting!("stocksage.native_max_debate_rounds", 1)
    put_setting!("stocksage.native_max_risk_rounds", 1)
    put_setting!("permissions.stocksage_analyze", "needs_confirmation")

    on_exit(fn ->
      Guard.reset_for_test()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf(home)
    end)

    :ok
  end

  test "approved native run persists native analysis, detail, objective, and delegate steps" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    params = %{
      ticker: "AAPL",
      analysis_date: "2026-05-15",
      user_id: "alice",
      engine: "native",
      evidence_mode: "fixture",
      thread_id: "thr_native_analysis",
      session_id: "sess_native_analysis"
    }

    context = %{
      confirmation: %{approved?: true, id: "native-confirmation"},
      trace_id: "trace-native-analysis"
    }

    assert {:ok, response} = Runner.run("run_analysis", params, context)

    assert response.status == :completed
    assert response.engine == "native"
    assert response.ticker == "AAPL"
    assert is_binary(response.analysis_id)
    assert is_binary(response.objective_id)
    assert response.summary =~ "decision synthesized"
    assert [%Node{} | _] = response.surface_nodes
    assert {:ok, _validated_nodes} = SurfaceNodes.validate_nodes(response.surface_nodes)

    surface_components = Enum.map(response.surface_nodes, & &1.component)
    assert :analysis_card in surface_components
    assert :agent_report_card in surface_components
    assert :debate_round_card in surface_components

    [action] = response.actions
    native_trace = get_in(action, [:stocksage, :native_trace])
    assert is_map(native_trace)
    assert length(native_trace["agent_reports"]) == 12
    assert native_trace["generation_modes"] == ["deterministic_advisory"]

    {:ok, analysis} = Analyses.get_analysis_with_details("alice", response.analysis_id)
    assert analysis.status == "completed"
    assert analysis.source == "native"
    assert analysis.engine == "native"
    assert analysis.recommendation in ["Buy", "Overweight", "Hold", "Underweight", "Sell"]
    assert analysis.objective_id == response.objective_id

    [detail] = analysis.details
    assert detail.agent == "native_coordinator"
    assert detail.content =~ "agent_reports"
    assert get_in(detail.payload, ["native_report", "final_trade_decision"])

    steps = Objectives.list_steps(response.objective_id)
    assert length(steps) == 12
    assert Enum.all?(steps, &(&1.kind == "delegate_agent"))
    assert Enum.all?(steps, &(&1.status == "completed"))

    kinds =
      4
      |> collect_fragment_signals()
      |> Enum.map(& &1.data.envelope.kind)

    assert :analysis_card in kinds
    assert :agent_report_card in kinds
    assert :debate_round_card in kinds
  end

  test "native engine is the default when no engine is passed" do
    assert {:ok, response} =
             Runner.run(
               "run_analysis",
               %{ticker: "MSFT", analysis_date: "2026-05-15", user_id: "alice"},
               %{}
             )

    assert response.status == :needs_confirmation
    assert response.confirmation["params_summary"]["engine"] == "native"
  end

  test "disabled native engine fails before creating a confirmation" do
    put_setting!("stocksage.native_engine_enabled", false)

    assert {:ok, response} =
             Runner.run(
               "run_analysis",
               %{ticker: "NVDA", analysis_date: "2026-05-15", user_id: "alice"},
               %{}
             )

    assert response.status == :error
    assert response.error == :native_engine_disabled
    refute Map.has_key?(response, :confirmation_id)
  end

  test "approved native run surfaces missing LLM credential failure reason" do
    with_missing_anthropic_key(fn ->
      assert {:ok, _subscription_id} =
               Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

      put_setting!("stocksage.native_llm_enabled", true)

      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-15",
        user_id: "alice",
        engine: "native",
        evidence_mode: "fixture",
        thread_id: "thr_native_missing_key",
        session_id: "sess_native_missing_key"
      }

      context = %{
        confirmation: %{approved?: true, id: "native-missing-key-confirmation"},
        trace_id: "trace-native-missing-key"
      }

      assert {:ok, response} = Runner.run("run_analysis", params, context)

      reason = "native_llm_unavailable: provider credential missing for anthropic"

      assert response.status == :failed
      assert response.error == reason
      assert response.message =~ reason
      assert [%Node{component: :analysis_card, props: failed_props}] = response.surface_nodes
      assert failed_props.status == "failed"
      assert failed_props.summary == reason
      assert {:ok, _validated_nodes} = SurfaceNodes.validate_nodes(response.surface_nodes)
      assert response.actions |> hd() |> get_in([:stocksage, :error]) == reason

      {:ok, analysis} = Analyses.get_analysis_with_details("alice", response.analysis_id)
      assert analysis.status == "failed"
      assert analysis.summary == reason
      assert analysis.metadata["error"] == reason

      signal =
        5
        |> collect_fragment_signals()
        |> Enum.find(&String.starts_with?(&1.data.envelope.id, "stocksage_analysis_failed_"))

      refute is_nil(signal)
      envelope = signal.data.envelope
      assert envelope.kind == :analysis_card
      assert envelope.thread_id == "thr_native_missing_key"
      assert envelope.surface.fallback_text == reason

      [node] = envelope.surface.nodes
      assert node.props.body == reason
    end)
  end

  test "async LiveView approval appends failed native result to the conversation" do
    with_missing_anthropic_key(fn ->
      put_setting!("stocksage.native_llm_enabled", true)

      assert {:ok, thread} = Conversations.create_general_thread("alice", "Run StockSage")

      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-15",
        user_id: "alice",
        engine: "native",
        evidence_mode: "fixture",
        thread_id: thread.id,
        session_id: "sess_native_async_missing_key"
      }

      assert {:ok, pending} =
               Runner.run("run_analysis", params, %{
                 channel: :live_view,
                 user_id: "alice",
                 operator_id: "alice",
                 thread_id: thread.id,
                 session_id: "sess_native_async_missing_key"
               })

      assert pending.status == :needs_confirmation

      assert {:ok, approval} =
               Runner.run("approve_confirmation", %{id: pending.confirmation_id}, %{
                 actor: "alice",
                 user_id: "alice",
                 operator_id: "alice",
                 channel: :live_view,
                 thread_id: thread.id,
                 session_id: "sess_native_async_missing_key"
               })

      assert approval.status == :completed
      assert approval.actions |> hd() |> get_in([:confirmation_metadata, :target_async?])

      reason = "native_llm_unavailable: provider credential missing for anthropic"

      record =
        wait_until(fn ->
          {:ok, record} = Confirmations.read(pending.confirmation_id)

          if record |> get_in(["operator_resolution", "target_status"]) |> to_string() ==
               "failed" do
            record
          end
        end)

      target_result = get_in(record, ["operator_resolution", "target_result"])
      assert target_result["error"] == reason

      message =
        wait_until(fn ->
          thread
          |> Conversations.list_messages()
          |> Enum.find(&(&1.role == "assistant" and String.contains?(&1.content, reason)))
        end)

      assert message.action_log["confirmation_id"] == pending.confirmation_id
      assert message.action_log["target_status"] == "failed"
      assert message.action_log["target_result"]["error"] == reason
    end)
  end

  test "approved native run can use Jido.AI provider-backed specialist generation" do
    original = Application.get_env(:allbert_assist, StockSage.Agents.LLM, [])

    Application.put_env(:allbert_assist, StockSage.Agents.LLM,
      provider: FakeLLMProvider,
      enabled?: true
    )

    Application.put_env(:allbert_assist, :stocksage_llm_test_pid, self())

    on_exit(fn ->
      Application.put_env(:allbert_assist, StockSage.Agents.LLM, original)
      Application.delete_env(:allbert_assist, :stocksage_llm_test_pid)
    end)

    put_setting!("stocksage.native_llm_enabled", true)

    params = %{
      ticker: "AAPL",
      analysis_date: "2026-05-15",
      user_id: "alice",
      engine: "native",
      evidence_mode: "fixture"
    }

    context = %{
      confirmation: %{approved?: true, id: "native-llm-confirmation"},
      trace_id: "trace-native-llm-analysis"
    }

    assert {:ok, response} = Runner.run("run_analysis", params, context)

    assert response.status == :completed

    {:ok, analysis} = Analyses.get_analysis_with_details("alice", response.analysis_id)
    assert analysis.recommendation == "Overweight"

    [action] = response.actions
    native_trace = get_in(action, [:stocksage, :native_trace])

    assert "jido_ai_llm" in native_trace["generation_modes"]

    assert Enum.any?(
             native_trace["agent_reports"],
             &(&1["agent_id"] == "stocksage.decision_synthesizer")
           )

    called =
      for _ <- 1..11 do
        assert_receive {:stocksage_llm_called, agent_id, _model_profile}, 1_000
        agent_id
      end

    assert "stocksage.research_manager" in called
    assert "stocksage.trader_plan" in called
    assert "stocksage.decision_synthesizer" in called
    refute "stocksage.quality_gate" in called
  end

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "test"}) do
      {:ok, _resolved} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
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

  defp with_missing_anthropic_key(fun) do
    original_llm = Application.get_env(:allbert_assist, StockSage.Agents.LLM, [])
    original_req_llm_key = Application.get_env(:req_llm, :anthropic_api_key)
    original_env_key = System.get_env("ANTHROPIC_API_KEY")

    try do
      Application.put_env(:allbert_assist, StockSage.Agents.LLM, enabled?: true)
      Application.delete_env(:req_llm, :anthropic_api_key)
      System.delete_env("ANTHROPIC_API_KEY")

      fun.()
    after
      Application.put_env(:allbert_assist, StockSage.Agents.LLM, original_llm)
      restore_req_llm_key(:anthropic_api_key, original_req_llm_key)
      restore_system_env("ANTHROPIC_API_KEY", original_env_key)
    end
  end

  defp restore_req_llm_key(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore_req_llm_key(key, value), do: Application.put_env(:req_llm, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition was not met")

  defp wait_until(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)

      false ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end
end
