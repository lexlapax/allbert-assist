defmodule AllbertAssist.TraceWorkspaceTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Settings
  alias AllbertAssist.Trace
  alias AllbertAssist.Workspace.Canvas
  alias AllbertAssist.Workspace.Ephemeral
  alias Jido.Signal

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-trace-workspace-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    :ok
  end

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

  test "runtime.trace_recent_entries_limit bounds workspace fragment trace context" do
    assert {:ok, _setting} =
             Settings.put("runtime.trace_recent_entries_limit", 1, %{audit?: false})

    trace =
      "Trace bounded workspace."
      |> turn("user-trace-bounded-workspace", "thread-trace-bounded-workspace", %{
        emitted_fragments: [
          %{fragment_id: "frag-keep", kind: "canvas_tile"},
          %{fragment_id: "frag-drop-from-trace", kind: "canvas_tile"}
        ],
        dropped_fragments: [
          %{fragment_id: "drop-keep", kind: "ephemeral_surface"},
          %{fragment_id: "drop-hide-from-trace", kind: "ephemeral_surface"}
        ]
      })
      |> Trace.text()

    assert trace =~ "- Recent emitted fragments: 1"
    assert trace =~ "frag-keep"
    refute trace =~ "frag-drop-from-trace"
    assert trace =~ "- Recent dropped fragments: 1"
    assert trace =~ "drop-keep"
    refute trace =~ "drop-hide-from-trace"
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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
