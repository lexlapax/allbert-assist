defmodule AllbertAssist.Agents.IntentAgentTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Agents.IntentAgent

  test "defines the v0.01 action surface as Jido action modules" do
    action_names = Enum.map(IntentAgent.action_modules(), & &1.name())

    assert action_names == [
             "direct_answer",
             "append_memory",
             "read_recent_memory",
             "list_skills",
             "read_skill",
             "plan_shell_command"
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

  test "answers plain prompts without selecting a side-effect action" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Hello Allbert.",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "side-effect-free"
    assert [%{name: "direct_answer", permission: :read_only}] = response.actions
  end

  test "selects append_memory for explicit memory requests without persistence" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Remember that I prefer short implementation updates.",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "Selected action: append_memory"
    assert response.message =~ "I prefer short implementation updates."
    assert [%{name: "append_memory", status: :selected, durable: false}] = response.actions
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
               destructive: true
             }
           ] = response.actions
  end
end
