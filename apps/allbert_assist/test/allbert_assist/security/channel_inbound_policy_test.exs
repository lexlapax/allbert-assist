defmodule AllbertAssist.Security.ChannelInboundPolicyTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Security.Risk
  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = temp_root("channel-inbound-policy")

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

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

  test "settings cannot lower channel inbound permission below confirmation floor" do
    assert {:error, {:invalid_setting, "permissions.channel_message_inbound", _reason}} =
             Settings.put("permissions.channel_message_inbound", "allowed", %{audit?: false})

    assert {:ok, resolved} =
             Settings.put("permissions.channel_message_inbound", "denied", %{audit?: false})

    assert resolved.value == "denied"
    assert Policy.resolve(:channel_message_inbound).effective == :denied
  end

  test "channel inbound permission is high risk with explanatory reasons" do
    risk = Risk.classify(:channel_message_inbound)

    assert risk.tier == :high
    assert Enum.any?(risk.reasons, &String.contains?(&1, "inbound channel message"))
  end

  defp temp_root(prefix) do
    Path.join(System.tmp_dir!(), "allbert-#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
