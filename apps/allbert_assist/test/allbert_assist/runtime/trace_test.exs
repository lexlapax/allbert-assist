defmodule AllbertAssist.Runtime.TraceTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Runtime.Trace
  alias AllbertAssist.Trace, as: LegacyTrace
  alias Jido.Signal

  setup do
    original_trace_config = Application.get_env(:allbert_assist, LegacyTrace)

    on_exit(fn ->
      restore_env(LegacyTrace, original_trace_config)
    end)

    :ok
  end

  test "trace text facade preserves existing markdown format" do
    turn = turn("Trace through facade")

    assert Trace.text(turn) == LegacyTrace.text(turn)
    assert Trace.text(turn) =~ "Trace format: v0.01-m6"
    refute Trace.text(turn) =~ "## Active Memory"
  end

  test "trace renders Active Memory after intent candidates without chunk bodies" do
    metadata = %{
      status: :completed,
      enabled?: true,
      query_terms_normalized: ["concise", "reports"],
      scope: %{thread_id: "thread-runtime-trace", active_app: nil, identity_namespace: "identity"},
      candidate_count_before_filter: 1,
      candidate_chunk_count_before_filter: 1,
      candidate_count_after_filter: 1,
      retrieved_chunks: [
        %{
          chunk_id: "active_memory:test",
          entry_path: "/tmp/persona.md",
          category: :identity,
          namespace: "identity",
          score: 0.42,
          recency_decay: 1.0,
          thread_affinity: 0.3,
          identity_inclusion: 1.5,
          lexical_match: 0.66,
          summary: "Concise reports"
        }
      ],
      excluded_chunks_sample: [
        %{chunk_id: "active_memory:excluded", score: 0.1, excluded_reason: :below_top_k}
      ]
    }

    trace =
      "Trace with active memory"
      |> turn()
      |> put_in([:response, :actions], [
        %{name: "direct_answer", direct_answer: %{active_memory: metadata}}
      ])
      |> Trace.text()

    assert trace =~ "## Intent Candidates"
    assert trace =~ "## Active Memory"
    assert trace =~ "## Memory Review"
    assert trace =~ "active_memory:test score=0.42"
    assert trace =~ "active_memory:excluded"
    refute trace =~ "Reports should stay terse."

    assert String.replace(trace, "\r\n", "\n") =~
             ~r/## Intent Candidates.*## Active Memory.*## Memory Review/s
  end

  test "record_turn facade preserves writer and enabled semantics" do
    test_pid = self()

    Application.put_env(:allbert_assist, LegacyTrace,
      enabled: true,
      writer: fn attrs ->
        send(test_pid, {:trace_attrs, attrs})
        {:ok, %{path: "trace-test.md", attrs: attrs}}
      end
    )

    assert Trace.enabled?()
    assert {:ok, %{path: "trace-test.md"}} = Trace.record_turn(turn("Record trace"))
    assert_receive {:trace_attrs, %{category: :traces, body: body}}
    assert body =~ "Record trace"
  end

  defp turn(text) do
    {:ok, input_signal} =
      Signal.new(
        "allbert.input.received",
        %{text: text},
        source: "/allbert/channels/test",
        subject: "user-runtime-trace"
      )

    {:ok, response_signal} =
      Signal.new(
        "allbert.agent.responded",
        %{message: "Runtime response: #{text}"},
        source: "/allbert/runtime",
        subject: "user-runtime-trace"
      )

    %{
      input_signal: input_signal,
      response_signal: response_signal,
      request: %{
        text: text,
        channel: :test,
        operator_id: "user-runtime-trace",
        user_id: "user-runtime-trace",
        thread_id: "thread-runtime-trace",
        session_id: nil,
        metadata: %{}
      },
      response: %{
        message: "Runtime response: #{text}",
        status: :completed,
        actions: [],
        diagnostics: []
      },
      workspace: %{
        canvas_tiles: [],
        ephemeral_surfaces: [],
        emitted_fragments: [],
        dropped_fragments: []
      },
      agent: AllbertAssist.Agents.IntentAgent
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
