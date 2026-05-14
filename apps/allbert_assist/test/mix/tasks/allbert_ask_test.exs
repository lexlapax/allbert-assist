defmodule Mix.Tasks.Allbert.AskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Execution.Audit
  alias AllbertAssist.Memory
  alias AllbertAssist.Runtime
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

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-ask-task-test-#{System.unique_integer([:positive])}"
      )

    runner = fn _signal, request ->
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
    assert output =~ "Actions:"
    assert output =~ "- direct_answer (completed)"
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

  test "default CLI runtime explains unsupported URL summarization without confirmation" do
    Application.delete_env(:allbert_assist, Runtime)

    output =
      capture_io(fn ->
        assert :ok = Ask.run(["check https://example.com/report and summarize it"])
      end)

    assert output =~ "Status: unsupported"
    assert output =~ "URL summarization is deferred to v0.11"
    assert output =~ "- unsupported_resource_workflow (unsupported)"
    assert Confirmations.list(status: :pending) == []
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
end
