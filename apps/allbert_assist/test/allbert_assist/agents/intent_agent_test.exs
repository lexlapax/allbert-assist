defmodule AllbertAssist.Agents.IntentAgentTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.Memory

  setup do
    original_config = Application.get_env(:allbert_assist, Memory)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-intent-memory-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Memory, root: root)

    on_exit(fn ->
      if original_config do
        Application.put_env(:allbert_assist, Memory, original_config)
      else
        Application.delete_env(:allbert_assist, Memory)
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "defines the v0.01 action surface as Jido action modules" do
    action_names = Enum.map(IntentAgent.action_modules(), & &1.name())

    assert action_names == [
             "direct_answer",
             "append_memory",
             "read_recent_memory",
             "list_skills",
             "read_skill",
             "plan_shell_command",
             "external_network_request"
           ]
  end

  test "answers capability prompts with safe v0.01 capabilities" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Hello Allbert. What can you do right now?",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "direct_answer"
    assert response.message =~ "append_memory"
    assert response.message =~ "plan_shell_command"
    assert response.message =~ "I cannot execute shell commands"
    assert [%{name: "list_skills"}] = response.actions
  end

  test "routes skill inspection prompts to the read-only list action" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "List the skills you can inspect.",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "v0.01-safe capabilities"
    assert [%{name: "list_skills", permission_decision: %{decision: :allowed}}] = response.actions
  end

  test "answers plain prompts without selecting a side-effect action" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Hello Allbert.",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "side-effect-free"

    assert [
             %{
               name: "direct_answer",
               permission: :read_only,
               permission_decision: %{decision: :allowed}
             }
           ] = response.actions
  end

  test "writes markdown memory for explicit memory requests", %{root: root} do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Remember that I prefer short implementation updates.",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-123"
             })

    assert response.status == :completed
    assert response.message =~ "Saved markdown memory"
    assert response.message =~ "I prefer short implementation updates."
    assert response.memory.path =~ Path.join(root, "preferences")
    assert File.exists?(response.memory.path)

    assert [
             %{
               name: "append_memory",
               status: :completed,
               durable: true,
               permission_decision: %{decision: :allowed}
             }
           ] = response.actions
  end

  test "reads markdown memory for recall requests" do
    assert {:ok, _response} =
             IntentAgent.respond(%{
               text: "Remember that my planning docs should be implementation-ready.",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-123"
             })

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "What do you remember about my planning docs?",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-456"
             })

    assert response.status == :completed
    assert response.message =~ "markdown-backed memories"
    assert response.message =~ "planning docs should be implementation-ready"
    assert [%{name: "read_recent_memory", memory_count: 1}] = response.actions
  end

  test "captures low-risk personal identity statements as preference memory", %{root: root} do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "my name is Sandeep",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-name"
             })

    assert response.status == :completed
    assert response.message =~ "Saved markdown memory"
    assert response.memory.path =~ Path.join(root, "preferences")
    assert response.memory.body =~ "Heuristic family: identity.name"
    assert response.memory.body =~ "Preferred name: Sandeep"
    assert File.exists?(response.memory.path)

    assert [
             %{
               name: "append_memory",
               memory_category: :preferences,
               permission_decision: %{decision: :allowed}
             }
           ] = response.actions
  end

  test "recalls personal identity from markdown memory" do
    assert {:ok, _response} =
             IntentAgent.respond(%{
               text: "my name is Sandeep",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-name"
             })

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "what is my name?",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-name-recall"
             })

    assert response.status == :completed
    assert response.message =~ "markdown-backed memories"
    assert response.message =~ "Preferred name: Sandeep"

    assert [%{name: "read_recent_memory", memory_count: 1, input: %{query: query}}] =
             response.actions

    assert query =~ "preferred name"
  end

  test "captures and recalls communication preferences" do
    assert {:ok, write_response} =
             IntentAgent.respond(%{
               text: "I prefer short implementation updates.",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-preference"
             })

    assert write_response.status == :completed
    assert write_response.memory.category == :preferences
    assert write_response.memory.body =~ "Heuristic family: local_context.preference"

    assert {:ok, read_response} =
             IntentAgent.respond(%{
               text: "how should you update me?",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-preference-recall"
             })

    assert read_response.status == :completed
    assert read_response.message =~ "short implementation updates"

    assert [%{name: "read_recent_memory", memory_count: 1, input: %{query: query}}] =
             read_response.actions

    assert query =~ "preference communication update"
  end

  test "does not silently store sensitive personal data without explicit memory intent", %{
    root: root
  } do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "I prefer my password to be hunter2.",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-sensitive"
             })

    assert response.status == :completed
    assert response.message =~ "side-effect-free"
    assert [%{name: "direct_answer"}] = response.actions
    assert [] = Path.wildcard(Path.join([root, "**", "*.md"]))
  end

  test "refuses command execution while offering only the plan action" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Run rm -rf /tmp/example",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :denied
    assert response.message =~ "I will not execute shell commands"
    assert response.message =~ "Selected action: plan_shell_command"

    assert [
             %{
               name: "plan_shell_command",
               status: :planned_not_executed,
               execution: :not_available,
               destructive: true,
               permission_decision: %{decision: :allowed},
               requested_permission_decision: %{decision: :denied}
             }
           ] = response.actions
  end

  test "requires confirmation for external network requests" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Fetch https://example.com from the internet",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "external network access"

    assert [
             %{
               name: "external_network_request",
               execution: :not_available,
               permission_decision: %{decision: :needs_confirmation}
             }
           ] = response.actions
  end
end
