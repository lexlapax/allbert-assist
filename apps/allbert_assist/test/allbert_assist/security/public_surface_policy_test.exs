defmodule AllbertAssist.Security.PublicSurfacePolicyTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Security.Risk
  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = temp_root("public-surface-policy")

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

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

  test "settings cannot lower public surface permission below confirmation floor" do
    assert {:error, {:invalid_setting, "permissions.public_surface_call_inbound", _reason}} =
             Settings.put("permissions.public_surface_call_inbound", "allowed", %{audit?: false})

    assert {:ok, resolved} =
             Settings.put("permissions.public_surface_call_inbound", "denied", %{audit?: false})

    assert resolved.value == "denied"
    assert Policy.resolve(:public_surface_call_inbound).effective == :denied
  end

  test "public surface permission is high risk with explanatory reasons" do
    risk = Risk.classify(:public_surface_call_inbound)

    assert risk.tier == :high
    assert Enum.any?(risk.reasons, &String.contains?(&1, "inbound public protocol"))
  end

  defp temp_root(prefix) do
    Path.join(System.tmp_dir!(), "allbert-#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
