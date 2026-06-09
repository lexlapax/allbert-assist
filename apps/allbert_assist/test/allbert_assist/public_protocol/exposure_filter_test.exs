defmodule AllbertAssist.PublicProtocol.ExposureFilterTest do
  use ExUnit.Case, async: false
  @moduletag :pure_async

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

  test "unknown tools are configuration errors" do
    assert {:error, {:non_exposable_tools, [%{name: "missing_tool", reason: :unknown_action}]}} =
             ExposureFilter.filter_tools(["missing_tool"])
  end
end
