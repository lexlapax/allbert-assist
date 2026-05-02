defmodule AllbertAssist.Actions.RegistryTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Multiply
  alias AllbertAssist.Actions.Registry

  test "returns the canonical runtime action names in stable order" do
    assert Registry.names() == [
             "direct_answer",
             "append_memory",
             "read_recent_memory",
             "list_skills",
             "read_skill",
             "activate_skill",
             "plan_shell_command",
             "external_network_request",
             "list_settings",
             "read_setting",
             "update_setting",
             "explain_setting",
             "list_provider_profiles",
             "list_model_profiles",
             "set_provider_credential",
             "security_status",
             "record_trace"
           ]

    assert Registry.duplicate_names() == []
  end

  test "returns the intent-agent action surface without internal actions" do
    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())

    assert "direct_answer" in agent_action_names
    assert "set_provider_credential" in agent_action_names
    refute "security_status" in agent_action_names
    refute "record_trace" in agent_action_names
  end

  test "resolves registered actions by name and module only" do
    assert {:ok, DirectAnswer} = Registry.resolve("direct_answer")
    assert {:ok, DirectAnswer} = Registry.resolve(:direct_answer)
    assert {:ok, DirectAnswer} = Registry.resolve(DirectAnswer)

    assert {:error, {:unknown_action, "missing_action"}} = Registry.resolve("missing_action")
    assert {:error, {:unknown_action, Multiply}} = Registry.resolve(Multiply)
    refute Registry.registered_module?(Multiply)
  end
end
