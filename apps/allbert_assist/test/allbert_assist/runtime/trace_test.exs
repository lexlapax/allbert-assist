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
