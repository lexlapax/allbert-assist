defmodule AllbertAssist.Security.ChannelInboundPolicySettingsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ReadyEffectContext

  # This row asserts Settings Central's refusal to store a value below the
  # safety floor, and that a stored value reaches Policy. Both halves of that
  # are residual behaviour, so it stays with the residual rather than following
  # Policy into the kernel.

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = temp_root("channel-inbound-policy")
    File.rm_rf!(root)

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "settings cannot lower channel inbound permission below confirmation floor" do
    assert {:error, {:invalid_setting, "permissions.channel_message_inbound", _reason}} =
             Settings.put(
               "permissions.channel_message_inbound",
               "allowed",
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, resolved} =
             Settings.put(
               "permissions.channel_message_inbound",
               "denied",
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert resolved.value == "denied"
    assert Policy.resolve(:channel_message_inbound).effective == :denied
  end

  defp temp_root(prefix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
