defmodule StockSage.TraceTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Trace

  setup do
    captured = :ets.new(:stocksage_trace_capture, [:set, :public])

    original = Application.get_env(:allbert_assist, Trace, [])

    Application.put_env(
      :allbert_assist,
      Trace,
      Keyword.merge(original,
        writer: fn attrs ->
          :ets.insert(captured, {:last, attrs})
          {:ok, %{path: "in_memory", body: Map.get(attrs, :body)}}
        end,
        enabled: true
      )
    )

    on_exit(fn ->
      Application.put_env(:allbert_assist, Trace, original)
      safe_ets_delete(captured)
    end)

    {:ok, captured: captured}
  end

  defp safe_ets_delete(table) do
    :ets.delete(table)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp build_turn(actions, response_status \\ :completed) do
    %{
      request: %{
        text: "analyze AAPL for 2026-05-01",
        channel: :cli,
        operator_id: "local",
        user_id: "alice",
        active_app: :stocksage,
        trace: true
      },
      input_signal: %{id: "sig-in", type: "allbert.input.received"},
      response_signal: %{id: "sig-out", type: "allbert.agent.responded"},
      response: %{
        status: response_status,
        message: "ok",
        actions: actions
      }
    }
  end

  test "renders the StockSage Analysis section for run_analysis turns", %{captured: captured} do
    action = %{
      name: "run_analysis",
      status: :completed,
      permission: :stocksage_analyze,
      stocksage: %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        engine: "tradingagents",
        analysis_id: "analysis_abc",
        bridge_duration_ms: 42,
        truncated: false,
        stub: false,
        summary: "AAPL stub summary",
        queue_entry_id: nil
      }
    }

    assert {:ok, _entry} = Trace.record_turn(build_turn([action]))

    [{:last, attrs}] = :ets.lookup(captured, :last)
    body = attrs.body

    assert body =~ "## StockSage Analysis"
    assert body =~ "Action: run_analysis"
    assert body =~ "Ticker: AAPL"
    assert body =~ "Analysis id: analysis_abc"
    assert body =~ "Bridge duration ms: 42"
    assert body =~ "Truncated: false"
    assert body =~ "Stub: false"
    assert body =~ "AAPL stub summary"
  end

  test "trace section renders Stub: true when the action came from force_stub mode",
       %{captured: captured} do
    # v0.22 audit closeout (Gap 1 — stub-mode visibility): the trace
    # section surfaces stub flag prominently so operators inspecting a
    # run after the fact can't miss that it came from the stub path.
    action = %{
      name: "run_analysis",
      status: :completed,
      permission: :stocksage_analyze,
      stocksage: %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        engine: "tradingagents",
        analysis_id: "analysis_stub_xyz",
        bridge_duration_ms: 5,
        truncated: false,
        stub: true,
        summary: "Stub analysis for AAPL on 2026-05-01 using tradingagents."
      }
    }

    assert {:ok, _entry} = Trace.record_turn(build_turn([action]))

    [{:last, attrs}] = :ets.lookup(captured, :last)
    body = attrs.body

    assert body =~ "Stub: true",
           "expected `Stub: true` line in trace section; got body:\n#{body}"
  end

  test "trace section defaults Stub: to false when the field is missing",
       %{captured: captured} do
    # Backward compatibility: actions persisted before the stub flag was
    # added to action metadata should still render a sensible value
    # rather than `Stub: ` or crashing.
    action = %{
      name: "run_analysis",
      status: :completed,
      permission: :stocksage_analyze,
      stocksage: %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        engine: "tradingagents",
        analysis_id: "analysis_legacy",
        bridge_duration_ms: 42,
        truncated: false,
        summary: "Legacy action without stub field"
      }
    }

    assert {:ok, _entry} = Trace.record_turn(build_turn([action]))

    [{:last, attrs}] = :ets.lookup(captured, :last)
    body = attrs.body

    assert body =~ "Stub: false",
           "expected `Stub: false` default in trace section when stub field is missing"
  end

  test "renders 'none' when no run_analysis action is present", %{captured: captured} do
    action = %{name: "list_analyses", status: :completed}
    assert {:ok, _entry} = Trace.record_turn(build_turn([action]))

    [{:last, attrs}] = :ets.lookup(captured, :last)
    body = attrs.body

    assert body =~ "## StockSage Analysis"
    refute body =~ "Action: run_analysis"
  end

  test "renders bounded native analysis summary, agent rows, debate rounds, and parity",
       %{captured: captured} do
    action = %{
      name: "run_analysis",
      status: :completed,
      permission: :stocksage_analyze,
      stocksage: %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        engine: "both",
        analysis_id: "analysis_native_trace",
        bridge_duration_ms: 123,
        truncated: false,
        stub: false,
        summary: "Native/Python parity run completed.",
        native_trace: %{
          agent_reports: [
            %{
              agent_id: "stocksage.market_context",
              status: "ok",
              summary: "Market context prepared for AAPL.",
              confidence: 0.72,
              duration_ms: 12,
              model_profile: "fast",
              generation_mode: "deterministic_advisory"
            },
            %{
              agent_id: "stocksage.decision_synthesizer",
              status: "ok",
              summary: "Hold decision synthesized for AAPL.",
              confidence: 0.81,
              duration_ms: 15,
              model_profile: "slow",
              generation_mode: "deterministic_advisory"
            }
          ],
          debate_rounds: [
            %{
              round_index: 1,
              bull_summary: "Bull thesis prepared.",
              bear_summary: "Bear thesis prepared.",
              risk_count: 3
            }
          ],
          generation_modes: ["deterministic_advisory"],
          parity_diff: %{
            "native_rating" => "Hold",
            "python_rating" => "Overweight",
            "rating_agreement" => 0.5,
            "confidence_delta" => 0.12,
            "parity_pass" => true
          }
        }
      }
    }

    assert {:ok, _entry} = Trace.record_turn(build_turn([action]))

    [{:last, attrs}] = :ets.lookup(captured, :last)
    body = attrs.body

    assert body =~ "## StockSage Native Analysis"
    assert body =~ "Execution posture: bounded advisory packets through native specialist agents"

    assert body =~
             "| stocksage.market_context | ok | 0.72 | deterministic_advisory | Market context prepared for AAPL. |"

    assert body =~ "Debate rounds:"

    assert body =~
             "Round 1: bull=Bull thesis prepared.; bear=Bear thesis prepared.; risk_reviews=3"

    assert body =~ "Parity diff:"
    assert body =~ "Native rating: Hold"
    assert body =~ "Python rating: Overweight"
    assert body =~ "Pass: true"
  end

  test "does not render the native analysis section for Python-only runs", %{captured: captured} do
    action = %{
      name: "run_analysis",
      status: :completed,
      permission: :stocksage_analyze,
      stocksage: %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        engine: "tradingagents",
        analysis_id: "analysis_python",
        bridge_duration_ms: 42,
        truncated: false,
        stub: false,
        summary: "Python bridge summary"
      }
    }

    assert {:ok, _entry} = Trace.record_turn(build_turn([action]))

    [{:last, attrs}] = :ets.lookup(captured, :last)
    body = attrs.body

    assert body =~ "## StockSage Native Analysis"
    refute body =~ "Execution posture: bounded advisory packets"
    refute body =~ "| stocksage.market_context |"
  end

  test "redacts raw bridge body, API keys, and secrets from the trace", %{captured: captured} do
    action = %{
      name: "run_analysis",
      status: :completed,
      permission: :stocksage_analyze,
      stocksage: %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        engine: "tradingagents",
        analysis_id: "analysis_abc",
        bridge_duration_ms: 42,
        truncated: false,
        summary: "bounded summary only"
      }
    }

    # Build a turn whose response message intentionally does NOT carry the
    # raw bridge body. We then assert that nothing surfaced contains the
    # raw markers the bridge might emit.
    turn = build_turn([action])
    assert {:ok, _entry} = Trace.record_turn(turn)

    [{:last, attrs}] = :ets.lookup(captured, :last)
    body = attrs.body

    refute body =~ "api_key"
    refute body =~ "password"
    refute body =~ "secret"
    refute body =~ "ssn"
  end

  test "redacts secret-like and oversized fields from a real-shape RunAnalysis result",
       %{captured: captured} do
    # v0.22 audit closeout (moderate gap 10): the audit found existing
    # redaction coverage was narrow. This test exercises a real-shape
    # RunAnalysis result — including potentially secret-bearing fields
    # an LLM agent transcript might surface — and asserts that no
    # secret/oversized data leaks into the rendered trace.

    secret_blob =
      """
      api_key=sk-not-a-real-key-but-formatted-like-one-AAAAAAAAAAAAAAAAAA
      OPENAI_API_KEY=sk-totally-fake-credential-please-redact
      password=hunter2-still-bad-do-not-leak
      access_token=ya29.GltUBT-fake-do-not-render
      authorization: Bearer fake-jwt.eyJhbGciOiJIUzI1.signature-bytes
      ssn 123-45-6789 should never appear
      """

    oversized_body = String.duplicate("y", 5_000)

    # A response.actions[].stocksage payload shaped like what a real bridge
    # might produce, with secret-like junk attached at the top level of the
    # action map (in fields a downstream consumer might think are "safe to
    # dump"). These should all be redacted by AllbertAssist.Security.Redactor.
    action = %{
      name: "run_analysis",
      status: :completed,
      permission: :stocksage_analyze,
      stocksage: %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        engine: "tradingagents",
        analysis_id: "analysis_redact",
        bridge_duration_ms: 4_711,
        truncated: true,
        summary: "AAPL stub summary, bounded operator-facing only",
        queue_entry_id: nil
      },
      # Fields that should NOT appear in the trace section at all because
      # their key names match the expanded sensitive-key fragments list.
      raw_bridge_body: secret_blob,
      raw_final_state: oversized_body,
      raw_response: secret_blob,
      api_key: "sk-leak-via-action-map",
      authorization: "Bearer fake-jwt-do-not-leak"
    }

    turn = build_turn([action])
    assert {:ok, _entry} = Trace.record_turn(turn)

    [{:last, attrs}] = :ets.lookup(captured, :last)
    body = attrs.body

    # Hard redaction assertions: none of these tokens should appear in any
    # form in the trace body. The Redactor strips by key name; downstream
    # consumers that try to dump secret-like raw content end up emitting
    # "[REDACTED]" instead of the value.
    refute body =~ "sk-not-a-real-key",
           "raw API-key shape leaked into trace"

    refute body =~ "OPENAI_API_KEY=sk-totally",
           "credential env-var assignment leaked"

    refute body =~ "hunter2",
           "password value leaked"

    refute body =~ "ya29.GltUBT",
           "OAuth-token-shaped credential leaked"

    refute body =~ "Bearer fake-jwt-do-not-leak",
           "Bearer authorization header leaked"

    refute body =~ "123-45-6789",
           "SSN-shaped value leaked"

    refute body =~ "sk-leak-via-action-map",
           "secret embedded in api_key field leaked"

    # Oversized raw_final_state must not appear; the trace should never
    # render unbounded body content from a raw_* field.
    refute String.contains?(body, oversized_body),
           "oversized raw body leaked into trace"

    assert byte_size(body) < 50_000,
           "trace body should not balloon when an action map carries secrets/oversize content"
  end

  test "bounds the summary to 200 chars in the trace section", %{captured: captured} do
    long = String.duplicate("x", 300)

    action = %{
      name: "run_analysis",
      status: :completed,
      permission: :stocksage_analyze,
      stocksage: %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        engine: "tradingagents",
        analysis_id: "analysis_abc",
        bridge_duration_ms: 0,
        truncated: true,
        summary: long
      }
    }

    assert {:ok, _entry} = Trace.record_turn(build_turn([action]))

    [{:last, attrs}] = :ets.lookup(captured, :last)
    body = attrs.body

    # Extract the Summary: line and ensure it does not contain a 300x payload
    summary_line =
      body
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, "- Summary:"))

    assert summary_line
    assert String.length(summary_line) <= 220
  end
end
