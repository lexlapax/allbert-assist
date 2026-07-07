defmodule AllbertAssist.Actions.Channels.SignalDoctorTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels.Signal.Doctor
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Signal, as: SignalPlugin
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments

  @aci "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001"

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_doctor_opts = Application.get_env(:allbert_assist, :signal_doctor_client_opts)
    original_plugins = PluginRegistry.registered_plugins()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-signal-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, :signal_doctor_client_opts, mode: :stub)

    PluginRegistry.clear()
    assert {:ok, "allbert.signal"} = PluginRegistry.register_module(SignalPlugin)
    Fragments.clear_cache()
    configure_signal!(root)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:signal_doctor_client_opts, original_doctor_opts)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "doctor action returns release-blocked envelope and persists state" do
    assert {:ok, %{status: :completed} = response} =
             Runner.run("signal_doctor", %{}, %{actor: "operator"})

    assert response.doctor.status == :implemented_not_released
    assert response.doctor.release_status == :implemented_not_released
    assert response.doctor.auth_ok
    refute response.doctor.endpoint_ok
    assert response.doctor.control_mode == "socket"
    refute response.doctor.control_local_only
    assert :implemented_not_released in response.doctor.diagnostics
    refute inspect(response) =~ "+15551234567"

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "implemented_not_released"
    assert state["release_status"] == "implemented_not_released"
    assert state["control_mode"] == "socket"
  end

  defp configure_signal!(root) do
    assert {:ok, _setting} =
             Settings.put("channels.signal.account_identifier", "+15551234567", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.signal.local_aci", @aci, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.signal.data_dir", Path.join(root, "signal"), %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.signal.identity_map",
               [%{external_user_id: @aci, user_id: "alice"}],
               %{audit?: false}
             )

    assert {:ok, _setting} = Settings.put("channels.signal.enabled", true, %{audit?: false})
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
