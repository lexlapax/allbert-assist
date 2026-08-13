defmodule AllbertSignal.Actions.DoctorTest do
  use AllbertAssist.DataCase, async: false

  import AllbertAssist.TestSupport.ActionEnvelopeAssertions

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias AllbertSignal.Actions.Doctor, as: SignalDoctor
  alias AllbertSignal.Doctor

  @aci "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001"

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_doctor_opts = Application.get_env(:allbert_signal, :signal_doctor_client_opts)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-signal-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_signal, :signal_doctor_client_opts, mode: :stub)

    Fragments.clear_cache()
    configure_signal!(root)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:signal_doctor_client_opts, original_doctor_opts)
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

    assert {:ok, direct_response} = SignalDoctor.run(%{}, action_context())

    assert_channel_envelope(direct_response,
      name: "signal_doctor",
      message:
        "Signal doctor: status=implemented_not_released auth_ok=true endpoint_ok=false " <>
          "adapter=#{direct_response.doctor.adapter_status} control=socket local_only=false " <>
          "diagnostics=implemented_not_released",
      status: :completed,
      action_status: :completed,
      decision: :allowed,
      diagnostics: [:implemented_not_released],
      metadata: %{
        doctor_status: :implemented_not_released,
        auth_ok: true,
        endpoint_ok: false,
        adapter_status: direct_response.doctor.adapter_status,
        control_mode: "socket",
        diagnostics: [:implemented_not_released]
      }
    )

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "implemented_not_released"
    assert state["release_status"] == "implemented_not_released"
    assert state["control_mode"] == "socket"
  end

  test "preserves the exact denial envelope before diagnostics run" do
    assert {:ok, response} = SignalDoctor.run(%{}, denied_context())

    assert response.doctor == %{}

    assert_channel_envelope(response,
      name: "signal_doctor",
      message: denied_message(),
      status: :denied,
      action_status: :denied,
      decision: :denied,
      diagnostics: [],
      metadata: %{error: :permission_denied}
    )
  end

  defp configure_signal!(root) do
    assert {:ok, _setting} =
             Settings.put(
               "channels.signal.account_identifier",
               "+15551234567",
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.signal.local_aci",
               @aci,
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.signal.data_dir",
               Path.join(root, "signal"),
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.signal.identity_map",
               [%{external_user_id: @aci, user_id: "alice"}],
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.signal.enabled",
               true,
               ReadyEffectContext.attach(%{audit?: false})
             )
  end

  defp action_context, do: %{actor: "operator"}
  defp denied_context, do: %{selected_action: "unregistered_boundary_probe"}

  defp denied_message,
    do: "Unknown or unregistered action boundary: \"unregistered_boundary_probe\"."

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_signal, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_signal, key, value)
end
