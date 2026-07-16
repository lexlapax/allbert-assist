defmodule AllbertAssist.Actions.Channels.TelegramDoctorTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Channels.TelegramDoctor
  alias AllbertAssist.Channels.Telegram.Doctor
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.TestSupport.ShippedRegistries

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_doctor_opts = Application.get_env(:allbert_assist, :telegram_doctor_client_opts)
    original_stub_result = Application.get_env(:allbert_assist, :telegram_client_stub_result)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-telegram-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, :telegram_doctor_client_opts, mode: :stub)

    PluginRegistry.clear()

    assert {:ok, "allbert.telegram"} =
             PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)

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
      ShippedRegistries.restore!()
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

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "ok"
    assert state["bot_username"] == "allbert_fixture_bot"
  end

  test "flags missing group allowlist as a warning" do
    assert {:ok, _setting} =
             Settings.put("channels.telegram.allow_group_chats", true, %{audit?: false})

    assert {:ok, response} = TelegramDoctor.run(%{}, context())

    assert response.doctor.status == :warning
    assert :missing_allowed_chat_ids in response.doctor.diagnostics
  end

  test "reports token rejection without leaking credentials" do
    Application.put_env(:allbert_assist, :telegram_client_stub_result, :unauthorized)

    assert {:ok, response} = TelegramDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :error
    assert :token_rejected in response.diagnostics
    refute inspect(response) =~ "123:secret"
  end

  defp context do
    %{
      actor: "local",
      channel: :test,
      request: %{channel: :test, user_id: "local", operator_id: "local"}
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
