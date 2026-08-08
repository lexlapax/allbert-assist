defmodule AllbertAssist.Security.PublicSurfacePolicyTest do
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

  test "public surface permission class has floor, settings key, and reason" do
    assert :public_surface_call_inbound in Policy.permission_classes()

    policy = Policy.resolve(:public_surface_call_inbound)

    assert policy.setting_key == "permissions.public_surface_call_inbound"
    assert policy.configured_decision == :needs_confirmation
    assert policy.effective == :needs_confirmation
    assert policy.safety_floor == :needs_confirmation
    assert policy.reason =~ "Inbound public protocol clients"

    assert Policy.safety_floor(:public_surface_call_inbound) == :needs_confirmation
  end

  test "public surface permission is high risk with explanatory reasons" do
    risk = Risk.classify(:public_surface_call_inbound)

    assert risk.tier == :high
    assert Enum.any?(risk.reasons, &String.contains?(&1, "inbound public protocol"))
  end
end
