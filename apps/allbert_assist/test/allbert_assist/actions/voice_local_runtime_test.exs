defmodule AllbertAssist.Actions.VoiceLocalRuntimeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Settings

  setup do
    reset_settings()
    on_exit(&reset_settings/0)
    :ok
  end

  test "doctor action reports Settings Central enablement and Security Central lifecycle decision" do
    assert {:ok, response} = Runner.run("voice_local_runtime_doctor", %{}, context())

    assert response.status == :completed
    assert response.doctor.local_runtime_present == true
    assert response.doctor.enabled? == false
    assert response.permission_decision.permission == :voice_local_runtime_manage
    assert response.permission_decision.decision == :allowed
  end

  test "start action fails closed when the local runtime is disabled in Settings Central" do
    assert {:ok, _setting} = Settings.put("voice.local_runtime.enabled", false, %{audit?: false})
    assert {:ok, response} = Runner.run("voice_local_runtime_start", %{}, context())

    assert response.status == :failed
    assert response.error == :voice_local_runtime_disabled
    assert response.permission_decision.permission == :voice_local_runtime_manage
  end

  test "start action honors Security Central denial" do
    assert {:ok, _setting} =
             Settings.put("permissions.voice_local_runtime_manage", "denied", %{audit?: false})

    assert {:ok, response} = Runner.run("voice_local_runtime_start", %{}, context())

    assert response.status == :denied
    assert response.error == :permission_denied
    assert response.permission_decision.decision == :denied
  end

  defp reset_settings do
    Settings.put("voice.local_runtime.enabled", false, %{audit?: false})
    Settings.put("permissions.voice_local_runtime_manage", "allowed", %{audit?: false})
  end

  defp context, do: %{actor: "local", channel: :test}
end
