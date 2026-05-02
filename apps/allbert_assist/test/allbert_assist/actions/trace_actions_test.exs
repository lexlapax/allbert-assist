defmodule AllbertAssist.Actions.TraceActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Trace.RecordTrace
  alias AllbertAssist.Memory
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Trace
  alias Jido.Signal

  setup do
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_trace_enabled_env = System.get_env("ALLBERT_TRACE_ENABLED")

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-trace-action-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Memory, root: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)
    System.delete_env("ALLBERT_TRACE_ENABLED")

    on_exit(fn ->
      restore_env(Memory, original_memory_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_system_env("ALLBERT_TRACE_ENABLED", original_trace_enabled_env)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "records an enabled trace through the action boundary", %{root: root} do
    Application.put_env(:allbert_assist, Trace, enabled: true)

    assert {:ok, response} = RecordTrace.run(%{turn: turn("Trace through action.")}, context())

    assert response.status == :completed
    assert response.trace_id =~ Path.join(root, "traces")
    assert File.exists?(response.trace_id)

    assert [
             %{
               name: "record_trace",
               status: :completed,
               permission: :memory_write,
               trace_metadata: %{trace_id: trace_id, error: nil}
             }
           ] = response.actions

    assert trace_id == response.trace_id

    trace = File.read!(trace_id)
    assert trace =~ "Skill metadata: direct-answer (built_in, trusted)"
    assert trace =~ "validation_status: :valid"
    assert trace =~ "## Security Metadata"
    assert trace =~ "risk: %{"
    assert trace =~ "policy:"
  end

  test "skips trace recording when tracing is disabled" do
    assert {:ok, response} = RecordTrace.run(%{turn: turn("Trace disabled.")}, context())

    assert response.status == :completed
    assert response.trace_id == nil
    assert [%{name: "record_trace", status: :skipped}] = response.actions
  end

  test "returns structured errors when trace writing fails" do
    Application.put_env(:allbert_assist, Trace,
      enabled: true,
      writer: fn _attrs -> {:error, :disk_full} end
    )

    assert {:ok, response} = RecordTrace.run(%{turn: turn("Trace failure.")}, context())

    assert response.status == :error
    assert response.trace_id == nil
    assert response.error == :disk_full

    assert [%{name: "record_trace", status: :error, trace_metadata: %{error: :disk_full}}] =
             response.actions
  end

  defp turn(text) do
    {:ok, input_signal} =
      Signal.new(
        "allbert.input.received",
        %{text: text},
        source: "/allbert/channels/test",
        subject: "local"
      )

    {:ok, response_signal} =
      Signal.new(
        "allbert.agent.responded",
        %{message: "Runtime response: #{text}"},
        source: "/allbert/runtime",
        subject: "local"
      )

    %{
      input_signal: input_signal,
      response_signal: response_signal,
      request: %{text: text, channel: :test, operator_id: "local", metadata: %{}},
      response: %{
        message: "Runtime response: #{text}",
        status: :completed,
        actions: [
          %{
            name: "direct_answer",
            skill_metadata: %{
              selected_skill: "direct-answer",
              source_scope: :built_in,
              trust_status: :trusted,
              capability_contract: %{
                validation_status: :valid,
                execution_eligible?: true
              }
            },
            permission_decision:
              PermissionGate.authorize(:read_only, %{
                request: %{operator_id: "local", channel: :test, input_signal_id: input_signal.id},
                selected_action: "direct_answer"
              })
          }
        ],
        diagnostics: []
      },
      agent: AllbertAssist.Agents.IntentAgent
    }
  end

  defp context do
    %{request: %{operator_id: "local", channel: :test, input_signal_id: "sig-trace"}}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
