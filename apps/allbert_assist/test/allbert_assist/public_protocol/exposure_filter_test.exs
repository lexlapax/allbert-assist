defmodule AllbertAssist.PublicProtocol.ExposureFilterTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.PublicProtocol.ExposureFilter

  test "agent exposure is necessary but settings and secret actions are denied first" do
    assert {:ok, list_settings} = Registry.capability("list_settings")
    assert list_settings.exposure == :agent

    assert ExposureFilter.non_exposable_reason(list_settings) ==
             {:blocked_execution_mode, :settings_read}

    assert {:ok, set_provider_credential} = Registry.capability("set_provider_credential")
    assert set_provider_credential.exposure == :agent

    assert ExposureFilter.non_exposable_reason(set_provider_credential) ==
             {:blocked_execution_mode, :secret_write}

    assert {:error, {:non_exposable_tools, rejected}} =
             ExposureFilter.filter_tools(["list_settings", "set_provider_credential"])

    assert Enum.map(rejected, & &1.name) == ["list_settings", "set_provider_credential"]
  end

  test "safe agent actions can be allowlisted explicitly" do
    assert {:ok, [capability]} = ExposureFilter.filter_tools(["direct_answer"])

    assert capability.name == "direct_answer"
    assert capability.exposure == :agent
  end

  test "public readback is exposable but confirmation decisions remain internal" do
    assert {:ok, [capability]} = ExposureFilter.filter_tools(["get_public_call_result"])

    assert capability.name == "get_public_call_result"
    assert capability.exposure == :agent
    assert capability.execution_mode == :read_only

    assert {:ok, approve_confirmation} = Registry.capability("approve_confirmation")
    assert ExposureFilter.non_exposable_reason(approve_confirmation) == :not_agent_exposable

    assert {:ok, deny_confirmation} = Registry.capability("deny_confirmation")
    assert ExposureFilter.non_exposable_reason(deny_confirmation) == :not_agent_exposable
  end

  test "Pi-mode coding actions are not public protocol tools" do
    for name <- ["read", "grep", "glob", "write", "edit", "bash"] do
      assert {:ok, capability} = Registry.capability(name)
      assert capability.exposure == :internal
      assert ExposureFilter.non_exposable_reason(capability) == :not_agent_exposable
    end

    assert {:error, {:non_exposable_tools, rejected}} =
             ExposureFilter.filter_tools(["read", "grep", "glob", "write", "edit", "bash"])

    assert Enum.map(rejected, & &1.reason) == [
             :not_agent_exposable,
             :not_agent_exposable,
             :not_agent_exposable,
             :not_agent_exposable,
             :not_agent_exposable,
             :not_agent_exposable
           ]
  end

  test "unknown tools are configuration errors" do
    assert {:error, {:non_exposable_tools, [%{name: "missing_tool", reason: :unknown_action}]}} =
             ExposureFilter.filter_tools(["missing_tool"])
  end
end
