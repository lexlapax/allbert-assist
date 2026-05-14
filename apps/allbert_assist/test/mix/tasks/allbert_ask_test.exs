defmodule Mix.Tasks.Allbert.AskTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Execution.Audit
  alias AllbertAssist.Memory
  alias AllbertAssist.Runtime
  alias AllbertAssist.Session
  alias AllbertAssist.Settings
  alias AllbertAssist.Trace
  alias Mix.Tasks.Allbert.Ask

  setup do
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_audit_config = Application.get_env(:allbert_assist, Audit)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_trace_enabled_env = System.get_env("ALLBERT_TRACE_ENABLED")
    parent = self()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-ask-task-test-#{System.unique_integer([:positive])}"
      )

    runner = fn _signal, request ->
      send(parent, {:agent_request, request})

      {:ok,
       %{
         message: "CLI response: #{request.text}",
         status: :completed,
         actions: [
           %{
             name: "direct_answer",
             status: :completed,
             permission_decision: %{decision: :allowed}
           }
         ]
       }}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)
    Application.put_env(:allbert_assist, Memory, root: root)
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Audit, root: Path.join(root, "execution"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)
    System.delete_env("ALLBERT_TRACE_ENABLED")

    on_exit(fn ->
      restore_env(Runtime, original_runtime_config)
      restore_env(Memory, original_memory_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Audit, original_audit_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_system_env("ALLBERT_TRACE_ENABLED", original_trace_enabled_env)
      Mix.Task.reenable("allbert.ask")
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "prints a runtime response for one prompt" do
    output =
      capture_io(fn ->
        assert :ok = Ask.run(["hello from cli"])
      end)

    assert output =~ "Status: completed"
    assert output =~ "CLI response: hello from cli"
    assert output =~ "Signal: "
    assert output =~ "Trace: none"
    assert output =~ "User: local"
    assert output =~ "Thread: thr_"
    assert output =~ "Actions:"
    assert output =~ "- direct_answer (completed)"
  end

  test "passes user and new thread options through the runtime" do
    output =
      capture_io(fn ->
        assert :ok = Ask.run(["--user", "alice", "--new-thread", "hello from alice"])
      end)

    assert output =~ "User: alice"
    assert output =~ "Thread: thr_"
    assert [%{user_id: "alice"} = thread] = Conversations.list_threads("alice")

    assert {:ok, %{messages: [user_message, assistant_message]}} =
             Conversations.show_thread("alice", thread.id)

    assert user_message.content == "hello from alice"
    assert assistant_message.content == "CLI response: hello from alice"
  end

  test "passes session option through runtime and prints active app" do
    user = "ask-session-#{System.unique_integer([:positive])}"
    session_id = "sess-1"

    on_exit(fn -> Session.clear(user, session_id) end)

    assert {:ok, _entry} = Session.set_active_app(user, session_id, :stocksage)

    output =
      capture_io(fn ->
        assert :ok =
                 Ask.run([
                   "--user",
                   user,
                   "--session",
                   session_id,
                   "hello from session"
                 ])
      end)

    assert output =~ "User: #{user}"
    assert output =~ "Session: #{session_id}"
    assert output =~ "Active app: stocksage"

    assert_received {:agent_request,
                     %{
                       user_id: ^user,
                       session_id: ^session_id,
                       active_app: :stocksage
                     }}
  end

  test "continues an explicit user-owned thread" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Existing")

    output =
      capture_io(fn ->
        assert :ok = Ask.run(["--user", "alice", "--thread", thread.id, "continue this"])
      end)

    assert output =~ "User: alice"
    assert output =~ "Thread: #{thread.id}"
  end

  test "rejects conflicting user/operator and thread options" do
    assert_raise Mix.Error, ~r/--user and --operator must match/, fn ->
      Ask.run(["--user", "alice", "--operator", "bob", "hello"])
    end

    assert_raise Mix.Error, ~r/--thread and --new-thread cannot be used together/, fn ->
      Ask.run(["--thread", "thr_existing", "--new-thread", "hello"])
    end

    assert_raise Mix.Error, ~r/--session is invalid: :invalid_session_id/, fn ->
      Ask.run(["--session", "", "hello"])
    end
  end

  test "can enable trace recording for a CLI turn", %{root: root} do
    output =
      capture_io(fn ->
        assert :ok = Ask.run(["--trace", "trace this cli prompt"])
      end)

    assert output =~ "Status: completed"
    assert output =~ "Trace: #{Path.join(root, "traces")}"

    [trace_path] = Path.wildcard(Path.join([root, "traces", "*.md"]))
    assert File.read!(trace_path) =~ "trace this cli prompt"
  end

  test "default CLI runtime can list, read, and activate registry-backed skills", %{root: root} do
    Application.delete_env(:allbert_assist, Runtime)

    list_output =
      capture_io(fn ->
        assert :ok = Ask.run(["--trace", "what skills are available?"])
      end)

    read_output =
      capture_io(fn ->
        assert :ok = Ask.run(["--trace", "read skill append-memory"])
      end)

    alias_output =
      capture_io(fn ->
        assert :ok = Ask.run(["--trace", "read skill append_memory"])
      end)

    activate_output =
      capture_io(fn ->
        assert :ok = Ask.run(["--trace", "activate skill append-memory"])
      end)

    assert list_output =~ "append-memory"
    assert list_output =~ "built_in"
    assert read_output =~ "Skill: Append Memory"
    assert read_output =~ "Capability actions: append_memory"
    assert alias_output =~ "Name: append-memory"
    assert activate_output =~ "## Skill Context"
    assert activate_output =~ "## v0.03 Safety Boundary"

    trace_bodies =
      root
      |> Path.join("traces/*.md")
      |> Path.wildcard()
      |> Enum.map(&File.read!/1)

    assert Enum.any?(trace_bodies, &String.contains?(&1, "## Skill Metadata"))
    assert Enum.any?(trace_bodies, &String.contains?(&1, "selected_skill: \"append-memory\""))
  end

  test "default CLI runtime routes command prompts to confirmed shell execution" do
    Application.delete_env(:allbert_assist, Runtime)
    put_execution_policy!(File.cwd!())

    output =
      capture_io(fn ->
        assert :ok = Ask.run(["run pwd"])
      end)

    assert output =~ "Status: needs_confirmation"
    assert output =~ "- run_shell_command (needs_confirmation)"
    assert output =~ "Confirmation: conf_"
    assert output =~ "Command: pwd"
    assert output =~ "Approval Handoff:"
    assert output =~ "Approval: conf_"
    assert output =~ "Resource local_path run_shell_command execute"
    assert output =~ "Allowed: approve, deny, details"
    assert output =~ "Approve: mix allbert.confirmations approve conf_"
    assert output =~ "Deny: mix allbert.confirmations deny conf_"

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "run_shell_command"
    assert pending["target_permission"] == "command_execute"
  end

  test "default CLI runtime renders URL summarization approval before fetching" do
    Application.delete_env(:allbert_assist, Runtime)
    configure_external()

    output =
      capture_io(fn ->
        assert :ok = Ask.run(["check https://example.com/report and summarize it"])
      end)

    assert output =~ "Status: needs_confirmation"
    assert output =~ "Operation: summarize_url"
    assert output =~ "- external_network_request (needs_confirmation)"
    assert output =~ "Approval Handoff:"
    assert output =~ "Resource remote_url summarize_url summarize"
    assert output =~ "consumer=url_summarizer"
    assert [_pending] = Confirmations.list(status: :pending)
  end

  test "raises when prompt is missing" do
    assert_raise Mix.Error, ~r/Usage: mix allbert.ask/, fn ->
      Ask.run([])
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp put_execution_policy!(workspace) do
    settings = %{
      "permissions" => %{"command_execute" => "allowed"},
      "execution" => %{
        "local" => %{
          "enabled" => true,
          "allowed_roots" => [workspace]
        }
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end
end
