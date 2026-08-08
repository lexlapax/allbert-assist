defmodule AllbertAssist.Security.ChannelInboundPolicyTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Kernel.Contract.TestProviders
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Security.Risk

  setup do
    # No operator value is set, so these rows read the built-in floor. Stating
    # that through the settings contract replaces a temporary Allbert Home and
    # its application-environment save/restore.
    on_exit(TestProviders.stub_settings!(%{}))
    :ok
  end

  test "channel inbound permission class has floor, settings key, and reason" do
    assert :channel_message_inbound in Policy.permission_classes()

    policy = Policy.resolve(:channel_message_inbound)

    assert policy.setting_key == "permissions.channel_message_inbound"
    assert policy.configured_decision == :needs_confirmation
    assert policy.effective == :needs_confirmation
    assert policy.safety_floor == :needs_confirmation
    assert policy.reason =~ "Inbound channel messages"

    assert Policy.safety_floor(:channel_message_inbound) == :needs_confirmation
  end

  test "channel inbound permission is high risk with explanatory reasons" do
    risk = Risk.classify(:channel_message_inbound)

    assert risk.tier == :high
    assert Enum.any?(risk.reasons, &String.contains?(&1, "inbound channel message"))
  end
end
