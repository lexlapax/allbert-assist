defmodule AllbertAssist.TraceWorkspaceTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Trace
  alias AllbertAssist.Workspace.Canvas
  alias AllbertAssist.Workspace.Ephemeral
  alias Jido.Signal

  test "text renders workspace sections from active state and recent fragment context" do
    user_id = "user-trace-workspace"
    thread_id = "thread-trace-workspace"

    assert {:ok, tile} =
             Canvas.add_tile(%{
               user_id: user_id,
               thread_id: thread_id,
               kind: :text,
               body: %{text: "analysis tile", api_key: "sk-secret"},
               metadata: %{source: "trace-test"}
             })

    assert {:ok, ephemeral} =
             Ephemeral.open(%{
               user_id: user_id,
               thread_id: thread_id,
               kind: :approval_card,
               body: %{title: "Approve network request", reason: "operator review"}
             })

    trace =
      "Trace workspace."
      |> turn(user_id, thread_id, %{
        emitted_fragments: [
          %{
            fragment_id: "frag-emitted",
            kind: "canvas_tile",
            component: :text,
            emitter_id: "objective-agent",
            emitted_at: "2026-05-18T18:00:00Z"
          }
        ],
        dropped_fragments: [
          %{
            fragment_id: "frag-dropped",
            kind: "ephemeral_surface",
            component: :approval_card,
            emitter_id: "objective-agent",
            reason: :signature_invalid
          }
        ]
      })
      |> Trace.text()

    assert trace =~ "## Response\n\nRuntime response: Trace workspace.\n\n### Workspace"
    assert trace =~ "## Workspace"
    assert trace =~ "- Canvas tiles: 1"
    assert trace =~ "- Ephemeral surfaces: 1"
    assert trace =~ tile.id
    assert trace =~ "analysis tile"
    assert trace =~ ephemeral.id
    assert trace =~ "approval_card"
    assert trace =~ "frag-emitted"
    assert trace =~ "frag-dropped"
    assert trace =~ "signature_invalid"
    assert trace =~ "[REDACTED]"
    refute trace =~ "sk-secret"
  end

  test "text renders none for an empty workspace" do
    trace =
      "Trace empty workspace."
      |> turn("user-trace-empty-workspace", "thread-trace-empty-workspace")
      |> Trace.text()

    assert trace =~ "### Workspace"
    assert trace =~ "- Canvas tiles: 0"
    assert trace =~ "- Ephemeral surfaces: 0"
    assert trace =~ "Canvas tiles:\nnone"
    assert trace =~ "Ephemeral surfaces:\nnone"
    assert trace =~ "Recent emitted fragments:\nnone"
    assert trace =~ "Recent dropped fragments:\nnone"
  end

  defp turn(text, user_id, thread_id, workspace \\ %{}) do
    {:ok, input_signal} =
      Signal.new(
        "allbert.input.received",
        %{text: text},
        source: "/allbert/channels/test",
        subject: user_id
      )

    {:ok, response_signal} =
      Signal.new(
        "allbert.agent.responded",
        %{message: "Runtime response: #{text}"},
        source: "/allbert/runtime",
        subject: user_id
      )

    %{
      input_signal: input_signal,
      response_signal: response_signal,
      request: %{
        text: text,
        channel: :test,
        operator_id: user_id,
        user_id: user_id,
        thread_id: thread_id,
        session_id: nil,
        metadata: %{}
      },
      response: %{
        message: "Runtime response: #{text}",
        status: :completed,
        actions: [],
        diagnostics: []
      },
      workspace: workspace,
      agent: AllbertAssist.Agents.IntentAgent
    }
  end
end
