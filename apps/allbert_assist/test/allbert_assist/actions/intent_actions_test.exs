defmodule AllbertAssist.Actions.IntentActionsTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Actions.Intent.AppendMemory
  alias AllbertAssist.Actions.Intent.ExternalNetworkRequest
  alias AllbertAssist.Actions.Intent.ListSkills
  alias AllbertAssist.Actions.Intent.PlanShellCommand
  alias AllbertAssist.Actions.Intent.ReadSkill

  test "list_skills returns static readable declarations" do
    assert {:ok, response} = ListSkills.run(%{}, %{})

    assert response.status == :completed
    assert response.message =~ "v0.01-safe capabilities"
    assert response.permission_decision.decision == :allowed
    assert Enum.any?(response.skills, &(&1.name == "append_memory"))
  end

  test "read_skill returns one skill declaration" do
    assert {:ok, response} = ReadSkill.run(%{name: "plan_shell_command"}, %{})

    assert response.status == :completed
    assert response.message =~ "Plan Shell Command"
    assert response.message =~ "command_plan"
    assert response.permission_decision.decision == :allowed
  end

  test "append_memory selects a non-durable memory write" do
    assert {:ok, response} =
             AppendMemory.run(%{memory: "I prefer short implementation updates."}, %{})

    assert response.status == :completed
    assert response.message =~ "Selected action: append_memory"
    assert response.permission_decision.decision == :allowed

    assert [
             %{
               durable: false,
               milestone: "v0.01 M5",
               permission_decision: %{decision: :allowed}
             }
           ] = response.actions
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
