defmodule AllbertWhatsApp.Actions.DoctorTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  import AllbertAssist.TestSupport.ActionEnvelopeAssertions

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertWhatsApp.Actions.Doctor
  alias AllbertWhatsApp.Doctor

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_doctor_opts = Application.get_env(:allbert_assist, :whatsapp_doctor_client_opts)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-whatsapp-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(:allbert_assist, :whatsapp_doctor_client_opts,
      plug: {Req.Test, __MODULE__}
    )

    Fragments.clear_cache()
    configure_whatsapp!()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:whatsapp_doctor_client_opts, original_doctor_opts)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "doctor action returns release-blocked redacted envelope and persists state" do
    assert {:ok, %{status: :completed} = response} =
             Runner.run("whatsapp_doctor", %{}, %{actor: "operator"})

    assert response.doctor.status == :implemented_not_released
    assert response.doctor.release_status == :implemented_not_released
    assert response.doctor.auth_ok
    refute response.doctor.endpoint_ok
    assert response.doctor.phone_number_id == "[REDACTED_PHONE]"
    assert :implemented_not_released in response.doctor.diagnostics
    refute inspect(response) =~ "whatsapp-secret"
    refute inspect(response) =~ "+15551234567"

    assert {:ok, direct_response} = WhatsAppDoctor.run(%{}, action_context())

    assert_channel_envelope(direct_response,
      name: "whatsapp_doctor",
      message:
        "WhatsApp doctor: status=implemented_not_released auth_ok=true endpoint_ok=false " <>
          "adapter=#{direct_response.doctor.adapter_status} phone=[REDACTED_PHONE] " <>
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
        diagnostics: [:implemented_not_released]
      }
    )

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "implemented_not_released"
    assert state["release_status"] == "implemented_not_released"
    assert state["phone_number_id"] == "[REDACTED_PHONE]"
  end

  test "preserves the exact denial envelope before diagnostics run" do
    assert {:ok, response} = WhatsAppDoctor.run(%{}, denied_context())

    assert response.doctor == %{}

    assert_channel_envelope(response,
      name: "whatsapp_doctor",
      message: denied_message(),
      status: :denied,
      action_status: :denied,
      decision: :denied,
      diagnostics: [],
      metadata: %{error: :permission_denied}
    )
  end

  defp configure_whatsapp! do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/whatsapp/access_token", "whatsapp-secret", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.access_token_ref",
               "secret://channels/whatsapp/access_token",
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.phone_number_id",
               "15551234567",
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.identity_map",
               [%{external_user_id: "+15550001111", user_id: "alice"}],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.webhook_enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )
  end

  defp action_context, do: %{actor: "operator"}
  defp denied_context, do: %{selected_action: "unregistered_boundary_probe"}

  defp denied_message,
    do: "Unknown or unregistered action boundary: \"unregistered_boundary_probe\"."

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
