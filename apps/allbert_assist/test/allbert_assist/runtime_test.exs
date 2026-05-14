defmodule AllbertAssist.RuntimeTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureLog

  alias AllbertAssist.Conversations
  alias AllbertAssist.Memory
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Trace

  setup do
    original_config = Application.get_env(:allbert_assist, Runtime)
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_trace_enabled_env = System.get_env("ALLBERT_TRACE_ENABLED")
    original_logger_level = Logger.level()
    parent = self()

    runner = fn signal, request ->
      send(parent, {:agent_runner_called, signal.type, request.text, request.channel})
      send(parent, {:agent_request, request})
      send(parent, {:agent_signal_data, signal.data})

      {:ok,
       %{
         message: "Runtime response: #{request.text}",
         status: :completed,
         actions: [
           %{
             name: "direct_answer",
             permission_decision: %{decision: :allowed}
           }
         ]
       }}
    end

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-runtime-trace-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)
    Application.put_env(:allbert_assist, Memory, root: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)
    System.delete_env("ALLBERT_TRACE_ENABLED")
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: original_logger_level)

      if original_config do
        Application.put_env(:allbert_assist, Runtime, original_config)
      else
        Application.delete_env(:allbert_assist, Runtime)
      end

      if original_memory_config do
        Application.put_env(:allbert_assist, Memory, original_memory_config)
      else
        Application.delete_env(:allbert_assist, Memory)
      end

      if original_settings_config do
        Application.put_env(:allbert_assist, Settings, original_settings_config)
      else
        Application.delete_env(:allbert_assist, Settings)
      end

      if original_trace_config do
        Application.put_env(:allbert_assist, Trace, original_trace_config)
      else
        Application.delete_env(:allbert_assist, Trace)
      end

      restore_system_env("ALLBERT_TRACE_ENABLED", original_trace_enabled_env)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "submits user input through the configured signal-first runner" do
    response =
      capture_log([level: :info], fn ->
        assert {:ok, response} =
                 Runtime.submit_user_input(%{
                   text: "Say hello from the runtime boundary.",
                   channel: :test,
                   operator_id: "local"
                 })

        assert response.message == "Runtime response: Say hello from the runtime boundary."
        assert response.status == :completed
        assert response.trace_id == nil
        assert response.diagnostics == []
        assert response.user_id == "local"
        assert response.operator_id == "local"
        assert String.starts_with?(response.thread_id, "thr_")
        assert response.session_id == nil
        assert is_binary(response.input_signal_id)
        assert is_binary(response.signal_id)
        response
      end)

    assert response =~ "allbert.input.received"
    assert response =~ "allbert.agent.responded"

    assert_received {:agent_runner_called, "allbert.input.received",
                     "Say hello from the runtime boundary.", :test}

    assert_received {:agent_request,
                     %{user_id: "local", operator_id: "local", thread_id: thread_id}}

    assert {:ok, thread} = Conversations.get_thread("local", thread_id)
    assert thread.kind == "general"

    assert {:ok, %{messages: messages}} = Conversations.show_thread("local", thread_id)

    assert Enum.map(messages, & &1.role) == ["user", "assistant"]

    assert Enum.map(messages, & &1.content) == [
             "Say hello from the runtime boundary.",
             "Runtime response: Say hello from the runtime boundary."
           ]
  end

  test "accepts string keys and default local identity" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               "text" => "Hello with string keys.",
               "channel" => "test"
             })

    assert response.message == "Runtime response: Hello with string keys."
    assert response.user_id == "local"
    assert response.operator_id == "local"
    assert String.starts_with?(response.thread_id, "thr_")

    assert_received {:agent_runner_called, "allbert.input.received", "Hello with string keys.",
                     "test"}
  end

  test "normalizes user_id as canonical identity and operator compatibility alias" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Hello as Alice.",
               channel: :test,
               user_id: "alice",
               session_id: "session-1"
             })

    assert response.user_id == "alice"
    assert response.operator_id == "alice"
    assert response.session_id == "session-1"
    assert String.starts_with?(response.thread_id, "thr_")

    assert_received {:agent_request,
                     %{
                       user_id: "alice",
                       operator_id: "alice",
                       thread_id: thread_id,
                       session_id: "session-1"
                     }}

    assert {:ok, _thread} = Conversations.get_thread("alice", thread_id)
  end

  test "passes bounded prior thread context to the agent after persisting current input" do
    assert {:ok, first} =
             Runtime.submit_user_input(%{
               text: "first turn",
               channel: :test,
               user_id: "alice",
               new_thread: true
             })

    assert_received {:agent_request, %{thread_context: %{messages: []}}}

    assert {:ok, second} =
             Runtime.submit_user_input(%{
               text: "second turn",
               channel: :test,
               user_id: "alice"
             })

    assert second.thread_id == first.thread_id

    assert_received {:agent_request,
                     %{
                       thread_id: thread_id,
                       thread_context: %{messages: context_messages, limit: 12}
                     }}

    assert thread_id == first.thread_id

    assert Enum.map(context_messages, & &1.content) == [
             "first turn",
             "Runtime response: first turn"
           ]
  end

  test "keeps user message but writes no assistant message when agent fails before response" do
    runner = fn _signal, _request -> {:error, :boom} end
    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)

    assert {:error, :boom} =
             Runtime.submit_user_input(%{
               text: "this will fail",
               channel: :test,
               user_id: "alice",
               new_thread: true
             })

    assert [thread] = Conversations.list_threads("alice")
    assert {:ok, %{messages: [message]}} = Conversations.show_thread("alice", thread.id)
    assert message.role == "user"
    assert message.content == "this will fail"
  end

  test "rejects conflicting user and operator identity before calling the runner" do
    assert {:error, {:identity_conflict, "alice", "bob"}} =
             Runtime.submit_user_input(%{
               text: "conflict",
               channel: :test,
               user_id: "alice",
               operator_id: "bob"
             })

    refute_received {:agent_runner_called, _, _, _}
    assert [] = Conversations.list_threads("alice")
    assert [] = Conversations.list_threads("bob")
  end

  test "selects explicit user-scoped threads and rejects cross-user thread access" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Existing")

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "continue existing",
               channel: :test,
               user_id: "alice",
               thread_id: thread.id
             })

    assert response.thread_id == thread.id

    assert {:error, {:thread_not_found, _}} =
             Runtime.submit_user_input(%{
               text: "try cross-user",
               channel: :test,
               user_id: "bob",
               thread_id: thread.id
             })
  end

  test "new_thread creates a fresh thread and conflicts with explicit thread_id" do
    assert {:ok, first} =
             Runtime.submit_user_input(%{
               text: "first",
               channel: :test,
               user_id: "alice"
             })

    assert {:ok, second} =
             Runtime.submit_user_input(%{
               text: "second",
               channel: :test,
               user_id: "alice",
               new_thread: true
             })

    assert first.thread_id != second.thread_id

    assert {:error, :thread_conflict} =
             Runtime.submit_user_input(%{
               text: "conflict",
               channel: :test,
               user_id: "alice",
               thread_id: first.thread_id,
               new_thread: true
             })
  end

  test "rejects empty text before calling the runner" do
    assert {:error, :empty_text} =
             Runtime.submit_user_input(%{
               text: "   ",
               channel: :test,
               operator_id: "local"
             })

    refute_received {:agent_runner_called, _, _, _}
  end

  test "records an inspectable markdown trace when tracing is enabled", %{root: root} do
    Application.put_env(:allbert_assist, Trace, enabled: true)

    response =
      capture_log([level: :info], fn ->
        assert {:ok, response} =
                 Runtime.submit_user_input(%{
                   text: "Trace this successful turn.",
                   channel: :test,
                   operator_id: "local"
                 })

        assert response.status == :completed
        assert response.trace_id =~ Path.join(root, "traces")
        assert response.diagnostics == []
        assert File.exists?(response.trace_id)
        response
      end)

    assert response =~ "allbert.action.requested"
    assert response =~ "/allbert/actions/record_trace"
    assert response =~ "allbert.trace.recorded"

    trace = File.read!(Path.wildcard(Path.join([root, "traces", "*.md"])) |> hd())
    assert trace =~ "Trace format: v0.01-m6"
    assert trace =~ "Input signal: "
    assert trace =~ "Response signal: "
    assert trace =~ "User: local"
    assert trace =~ "Thread: thr_"
    assert trace =~ "Agent: AllbertAssist.Agents.IntentAgent"
    assert trace =~ "Model alias: local"
    assert trace =~ "Selected action: direct_answer"
    assert trace =~ "Permission decision:"
    assert trace =~ "## Security Metadata"
    assert trace =~ "Trace this successful turn."
    assert trace =~ "Runtime response: Trace this successful turn."
  end

  test "ordinary conversation turns do not write markdown memory when tracing is disabled", %{
    root: root
  } do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Plain direct answer.",
               channel: :test,
               user_id: "alice",
               new_thread: true
             })

    assert response.status == :completed
    assert Path.wildcard(Path.join(root, "**/*.md")) == []
  end

  test "trace write failures do not crash the runtime response" do
    Application.put_env(:allbert_assist, Trace,
      enabled: true,
      writer: fn _attrs -> {:error, :disk_full} end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Trace failure should not fail the turn.",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.trace_id == nil
    assert [%{source: :trace, error: ":disk_full"}] = response.diagnostics
  end

  test "traces denied action metadata when tracing is enabled", %{root: root} do
    runner = fn _signal, _request ->
      {:ok,
       %{
         message: "I will not execute shell commands.",
         status: :denied,
         actions: [
           %{
             name: "plan_shell_command",
             permission_decision: %{decision: :allowed},
             requested_permission_decision: %{decision: :denied}
           }
         ]
       }}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)
    Application.put_env(:allbert_assist, Trace, enabled: true)

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Run rm -rf /tmp/example",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :denied
    assert File.exists?(response.trace_id)

    trace = File.read!(Path.wildcard(Path.join([root, "traces", "*.md"])) |> hd())
    assert trace =~ "Status: denied"
    assert trace =~ "Selected action: plan_shell_command"
    assert trace =~ "requested_permission_decision"
    assert trace =~ "decision: :denied"
    refute trace =~ "command output"
  end

  test "renders skill metadata explicitly when tracing is enabled", %{root: root} do
    runner = fn _signal, _request ->
      {:ok,
       %{
         message: "Activated append-memory.",
         status: :completed,
         actions: [
           %{
             name: "activate_skill",
             permission_decision: %{decision: :allowed},
             skill_metadata: %{
               selected_skill: "append-memory",
               source_scope: :built_in,
               trust_status: :trusted,
               kind: :native_action,
               activation_mode: :progressive_disclosure,
               resource_inventory: %{count: 0, paths: []}
             }
           }
         ]
       }}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)
    Application.put_env(:allbert_assist, Trace, enabled: true)

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Activate skill append-memory",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert File.exists?(response.trace_id)

    trace = File.read!(Path.wildcard(Path.join([root, "traces", "*.md"])) |> hd())
    assert trace =~ "Skill metadata: append-memory (built_in, trusted)"
    assert trace =~ "## Skill Metadata"
    assert trace =~ "selected_skill: \"append-memory\""
    assert trace =~ "resource_inventory"
  end

  test "records traces when runtime.trace_default is enabled in settings", %{root: root} do
    assert {:ok, _resolved} =
             Settings.put("runtime.trace_default", "enabled", %{actor: "local", channel: :test})

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Trace through settings.",
               channel: :test,
               operator_id: "local"
             })

    assert response.trace_id =~ Path.join(root, "traces")
    assert File.exists?(response.trace_id)
  end

  test "denied_only trace default records denied turns only", %{root: root} do
    runner = fn _signal, _request ->
      {:ok,
       %{
         message: "Denied.",
         status: :denied,
         actions: [%{name: "plan_shell_command", permission_decision: %{decision: :denied}}]
       }}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)

    assert {:ok, _resolved} =
             Settings.put("runtime.trace_default", "denied_only", %{
               actor: "local",
               channel: :test
             })

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Run rm -rf /tmp/example",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :denied
    assert response.trace_id =~ Path.join(root, "traces")
  end

  test "documents the first runtime signal names" do
    assert Runtime.signal_types() == %{
             input_received: "allbert.input.received",
             agent_responded: "allbert.agent.responded",
             action_requested: "allbert.action.requested",
             action_completed: "allbert.action.completed",
             memory_appended: "allbert.memory.appended",
             trace_recorded: "allbert.trace.recorded"
           }
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
