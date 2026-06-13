defmodule AllbertAssist.Actions.VoiceLocalRuntimeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    # Isolate Settings Central per test. This lane is single-VM serial, but an
    # earlier serial test can leave an orphan app setting in the shared store
    # (e.g. a stocksage setting persisted while stocksage was registered, then
    # the app unregistered), which makes an unrelated Settings.put fail
    # validation with {:unknown_setting, "stocksage"}. A per-test home gives a
    # clean store so these checks are order-independent.
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-voice-runtime-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    reset_settings()

    on_exit(fn ->
      restore_app_env(Paths, original_paths)
      restore_app_env(Settings, original_settings)
      File.rm_rf(home)
    end)

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)

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
