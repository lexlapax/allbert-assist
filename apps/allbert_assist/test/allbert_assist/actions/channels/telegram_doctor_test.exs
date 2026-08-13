defmodule AllbertTelegram.Actions.DoctorTest do
  use AllbertAssist.DataCase, async: false

  import AllbertAssist.TestSupport.ActionEnvelopeAssertions

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias AllbertTelegram.Actions.Doctor, as: TelegramDoctor
  alias AllbertTelegram.Doctor

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_doctor_opts = Application.get_env(:allbert_telegram, :telegram_doctor_client_opts)
    original_stub_result = Application.get_env(:allbert_telegram, :telegram_client_stub_result)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-telegram-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_telegram, :telegram_doctor_client_opts, mode: :stub)

    Fragments.clear_cache()

    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/telegram/bot_token", "123:secret", %{
               audit?: false
             })

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:telegram_doctor_client_opts, original_doctor_opts)
      restore_app_env(:telegram_client_stub_result, original_stub_result)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "returns and persists a redacted success envelope" do
    assert {:ok, response} = TelegramDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :ok
    assert response.doctor.auth_ok
    assert response.doctor.endpoint_ok
    assert response.doctor.poller_status in [:disabled, :not_started]
    assert response.doctor.bot_username == "allbert_fixture_bot"
    assert response.message =~ "Telegram doctor"
    refute inspect(response) =~ "123:secret"

    assert_channel_envelope(response,
      name: "telegram_doctor",
      message:
        "Telegram doctor: status=ok auth_ok=true endpoint_ok=true " <>
          "poller=#{response.doctor.poller_status} bot=allbert_fixture_bot",
      status: :completed,
      action_status: :completed,
      decision: :allowed,
      diagnostics: [],
      metadata: %{
        doctor_status: :ok,
        auth_ok: true,
        endpoint_ok: true,
        poller_status: response.doctor.poller_status,
        diagnostics: []
      }
    )

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "ok"
    assert state["bot_username"] == "allbert_fixture_bot"
  end

  test "flags missing group allowlist as a warning" do
    assert {:ok, _setting} =
             Settings.put(
               "channels.telegram.allow_group_chats",
               true,
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, response} = TelegramDoctor.run(%{}, context())

    assert response.doctor.status == :warning
    assert :missing_allowed_chat_ids in response.doctor.diagnostics
  end

  test "reports token rejection without leaking credentials" do
    Application.put_env(:allbert_telegram, :telegram_client_stub_result, :unauthorized)

    assert {:ok, response} = TelegramDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :error
    assert :token_rejected in response.diagnostics
    refute inspect(response) =~ "123:secret"
  end

  test "preserves the exact denial envelope before diagnostics run" do
    assert {:ok, response} = TelegramDoctor.run(%{}, denied_context())

    assert response.doctor == %{}

    assert_channel_envelope(response,
      name: "telegram_doctor",
      message: denied_message(),
      status: :denied,
      action_status: :denied,
      decision: :denied,
      diagnostics: [],
      metadata: %{error: :permission_denied}
    )
  end

  defp context do
    %{
      actor: "local",
      channel: :test,
      request: %{channel: :test, user_id: "local", operator_id: "local"}
    }
  end

  defp denied_context, do: %{selected_action: "unregistered_boundary_probe"}

  defp denied_message,
    do: "Unknown or unregistered action boundary: \"unregistered_boundary_probe\"."

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_telegram, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_telegram, key, value)
end
