defmodule AllbertAssist.Actions.IntentActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Intent.AppendMemory
  alias AllbertAssist.Actions.Intent.ExternalNetworkRequest
  alias AllbertAssist.Actions.Intent.ListSkills
  alias AllbertAssist.Actions.Intent.PlanShellCommand
  alias AllbertAssist.Actions.Intent.ReadRecentMemory
  alias AllbertAssist.Actions.Intent.ReadSkill
  alias AllbertAssist.Memory

  setup do
    original_config = Application.get_env(:allbert_assist, Memory)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-action-memory-test-#{System.unique_integer([:positive])}"
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

  test "list_skills returns registry-backed readable declarations" do
    assert {:ok, response} = ListSkills.run(%{}, %{})

    assert response.status == :completed
    assert response.message =~ "v0.01-safe capabilities"
    assert response.permission_decision.decision == :allowed
    assert Enum.any?(response.skills, &(&1.name == "append-memory"))
  end

  test "read_skill returns one skill declaration" do
    assert {:ok, response} = ReadSkill.run(%{name: "plan_shell_command"}, %{})

    assert response.status == :completed
    assert response.message =~ "Plan Shell Command"
    assert response.message =~ "command_plan"
    assert response.permission_decision.decision == :allowed
  end

  test "append_memory writes durable markdown", %{root: root} do
    assert {:ok, response} =
             AppendMemory.run(
               %{memory: "I prefer short implementation updates."},
               %{request: %{input_signal_id: "sig-123", operator_id: "local", channel: :test}}
             )

    assert response.status == :completed
    assert response.message =~ "Saved markdown memory"
    assert response.permission_decision.decision == :allowed
    assert response.memory.path =~ Path.join(root, "preferences")
    assert File.exists?(response.memory.path)

    assert [
             %{
               durable: true,
               memory_path: memory_path,
               memory_category: :preferences,
               permission_decision: %{decision: :allowed}
             }
           ] = response.actions

    assert memory_path == response.memory.path
  end

  test "append_memory stores heuristic identity memory under preferences", %{root: root} do
    assert {:ok, response} =
             AppendMemory.run(
               %{
                 memory: """
                 Heuristic family: identity.name
                 Inferred memory: Preferred name: Sandeep
                 Original statement: my name is Sandeep
                 """
               },
               %{request: %{input_signal_id: "sig-name", operator_id: "local", channel: :test}}
             )

    assert response.status == :completed
    assert response.memory.path =~ Path.join(root, "preferences")
    assert response.memory.category == :preferences
    assert response.memory.body =~ "Preferred name: Sandeep"
  end

  test "read_recent_memory returns markdown-backed entries" do
    assert {:ok, _response} =
             AppendMemory.run(
               %{memory: "My planning docs should be implementation-ready."},
               %{request: %{input_signal_id: "sig-123", operator_id: "local", channel: :test}}
             )

    assert {:ok, response} =
             ReadRecentMemory.run(
               %{query: "What do you remember about my planning docs?"},
               %{}
             )

    assert response.status == :completed
    assert response.message =~ "markdown-backed memories"
    assert [%{body: body}] = response.memories
    assert body =~ "planning docs"
  end

  test "plan_shell_command never executes requested command" do
    assert {:ok, response} =
             PlanShellCommand.run(%{command: "rm -rf /tmp/example"}, %{})

    assert response.status == :denied
    assert response.message =~ "I will not execute shell commands"
    assert response.permission_decision.decision == :denied

    assert [
             %{
               execution: :not_available,
               destructive: true,
               permission_decision: %{decision: :allowed},
               requested_permission_decision: %{decision: :denied}
             }
           ] = response.actions
  end

  test "external_network_request requires confirmation and makes no call" do
    assert {:ok, response} =
             ExternalNetworkRequest.run(%{request: "fetch https://example.com"}, %{})

    assert response.status == :needs_confirmation
    assert response.message =~ "I will not use external network access"
    assert response.permission_decision.decision == :needs_confirmation

    assert [
             %{
               execution: :not_available,
               permission: :external_network,
               permission_decision: %{decision: :needs_confirmation}
             }
           ] = response.actions
  end
end
