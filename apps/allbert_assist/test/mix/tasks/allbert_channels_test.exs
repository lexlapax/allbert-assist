defmodule Mix.Tasks.Allbert.ChannelsTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Discord, as: DiscordPlugin
  alias AllbertAssist.Plugins.Email, as: EmailPlugin
  alias AllbertAssist.Plugins.Matrix, as: MatrixPlugin
  alias AllbertAssist.Plugins.Signal, as: SignalPlugin
  alias AllbertAssist.Plugins.Slack, as: SlackPlugin
  alias AllbertAssist.Plugins.Telegram, as: TelegramPlugin
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin
  alias AllbertAssist.Plugins.WhatsApp, as: WhatsAppPlugin
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace
  alias Mix.Tasks.Allbert.Channels, as: ChannelsTask

  setup {Req.Test, :verify_on_exit!}

  defmodule FakeDoctorImapClient do
    def connect(_host, _port, opts), do: {:ok, %{opts: opts}}
    def login(conn, _username, "imap-secret"), do: {:ok, conn}
    def select_mailbox(conn, _mailbox), do: {:ok, conn}
    def search_unseen(_conn), do: {:ok, []}
    def logout(_conn), do: :ok
  end

  setup do
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_plugins = PluginRegistry.registered_plugins()
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    original_telegram_doctor_opts =
      Application.get_env(:allbert_assist, :telegram_doctor_client_opts)

    original_email_doctor_imap_client =
      Application.get_env(:allbert_assist, :email_doctor_imap_client)

    original_matrix_doctor_opts =
      Application.get_env(:allbert_assist, :matrix_doctor_client_opts)

    original_whatsapp_doctor_opts =
      Application.get_env(:allbert_assist, :whatsapp_doctor_client_opts)

    original_signal_doctor_opts =
      Application.get_env(:allbert_assist, :signal_doctor_client_opts)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-channels-task-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Memory, root: Path.join(root, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, :telegram_doctor_client_opts, mode: :stub)
    Application.put_env(:allbert_assist, :email_doctor_imap_client, FakeDoctorImapClient)
    Application.put_env(:allbert_assist, :matrix_doctor_client_opts, plug: {Req.Test, __MODULE__})
    Application.put_env(:allbert_assist, :whatsapp_doctor_client_opts, mode: :stub)
    Application.put_env(:allbert_assist, :signal_doctor_client_opts, mode: :stub)
    Application.delete_env(:allbert_assist, Trace)
    register_channel_plugins()

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})
        {:ok, %{message: "Task channel response: #{request.text}", status: :completed}}
      end
    )

    on_exit(fn ->
      restore_env(Memory, original_memory_config)
      restore_env(Paths, original_paths_config)
      restore_plugins(original_plugins)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_app_env(:telegram_doctor_client_opts, original_telegram_doctor_opts)
      restore_app_env(:email_doctor_imap_client, original_email_doctor_imap_client)
      restore_app_env(:matrix_doctor_client_opts, original_matrix_doctor_opts)
      restore_app_env(:whatsapp_doctor_client_opts, original_whatsapp_doctor_opts)
      restore_app_env(:signal_doctor_client_opts, original_signal_doctor_opts)
      Mix.Task.reenable("allbert.channels")
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  defp register_channel_plugins do
    PluginRegistry.clear()
    PluginRegistry.register_module(TelegramPlugin)
    PluginRegistry.register_module(EmailPlugin)
    PluginRegistry.register_module(DiscordPlugin)
    PluginRegistry.register_module(SlackPlugin)
    PluginRegistry.register_module(MatrixPlugin)
    PluginRegistry.register_module(WhatsAppPlugin)
    PluginRegistry.register_module(SignalPlugin)
    PluginRegistry.register_module(TUIPlugin)
    Fragments.clear_cache()
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  test "lists and shows channel summaries through registered actions" do
    list_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["list"])
      end)

    assert list_output =~ "telegram provider=telegram_bot_api"
    assert list_output =~ "email provider=email_imap"
    assert list_output =~ "discord provider=discord_gateway"
    assert list_output =~ "slack provider=slack_socket_mode"
    assert list_output =~ "matrix provider=matrix_client_server"
    assert list_output =~ "whatsapp provider=whatsapp_cloud_api"
    assert list_output =~ "signal provider=signal_cli_jsonrpc"
    assert list_output =~ "tui provider=terminal"
    refute list_output =~ "token"

    Mix.Task.reenable("allbert.channels")

    show_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["show", "telegram"])
      end)

    assert show_output =~ "Channel: telegram"
    assert show_output =~ "Provider: telegram_bot_api"

    Mix.Task.reenable("allbert.channels")

    email_show_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["show", "email"])
      end)

    assert email_show_output =~ "Channel: email"
    assert email_show_output =~ "Provider: email_imap"

    Mix.Task.reenable("allbert.channels")

    discord_show_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["show", "discord"])
      end)

    assert discord_show_output =~ "Channel: discord"
    assert discord_show_output =~ "Provider: discord_gateway"
    assert discord_show_output =~ "Doctor: not_run"

    Mix.Task.reenable("allbert.channels")

    slack_show_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["show", "slack"])
      end)

    assert slack_show_output =~ "Channel: slack"
    assert slack_show_output =~ "Provider: slack_socket_mode"
    assert slack_show_output =~ "Doctor: not_run"

    Mix.Task.reenable("allbert.channels")

    matrix_show_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["show", "matrix"])
      end)

    assert matrix_show_output =~ "Channel: matrix"
    assert matrix_show_output =~ "Provider: matrix_client_server"
    assert matrix_show_output =~ "Doctor: not_run"

    Mix.Task.reenable("allbert.channels")

    whatsapp_show_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["show", "whatsapp"])
      end)

    assert whatsapp_show_output =~ "Channel: whatsapp"
    assert whatsapp_show_output =~ "Provider: whatsapp_cloud_api"
    assert whatsapp_show_output =~ "Doctor: not_run"

    Mix.Task.reenable("allbert.channels")

    signal_show_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["show", "signal"])
      end)

    assert signal_show_output =~ "Channel: signal"
    assert signal_show_output =~ "Provider: signal_cli_jsonrpc"
    assert signal_show_output =~ "Doctor: not_run"

    Mix.Task.reenable("allbert.channels")

    tui_show_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["show", "tui"])
      end)

    assert tui_show_output =~ "Channel: tui"
    assert tui_show_output =~ "Provider: terminal"
  end

  test "prints descriptor-derived channel parity report" do
    parity_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["--parity"])
      end)

    assert parity_output =~ "channel"
    assert parity_output =~ "live_view"
    assert parity_output =~ "telegram"
    assert parity_output =~ "matrix"
    assert parity_output =~ "tui"
    assert parity_output =~ "typed_command+link+list"
    assert parity_output =~ "typed_command+list"
    assert parity_output =~ "turn_complete"
    assert parity_output =~ "channels.matrix.identity_map"
    assert parity_output =~ "channels.tui.identity_map"
    assert parity_output =~ "implemented"
    refute parity_output =~ "secret"
    refute parity_output =~ "token"
  end

  test "prints shared operator channel status report" do
    status_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["status"])
      end)

    assert status_output =~ "Channels ("
    assert status_output =~ "Channels.Supervisor:"
    assert status_output =~ "telegram: provider=telegram_bot_api"
    assert status_output =~ "tui: provider=terminal"
    assert status_output =~ "credentials="
    refute status_output =~ "secret://"
    refute status_output =~ "bot_token"
    refute status_output =~ "app_token"
  end

  test "checks Matrix WhatsApp and Signal setup readiness independently" do
    matrix_incomplete =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["setup-check", "matrix"])
      end)

    assert matrix_incomplete =~ "matrix setup status=incomplete"
    assert matrix_incomplete =~ "missing_enabled"
    assert matrix_incomplete =~ "mix allbert.test external-smoke -- matrix"
    refute matrix_incomplete =~ "matrix-secret"

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["matrix", "set-token", "matrix-secret"])
    end)

    assert {:ok, _setting} =
             Settings.put("channels.matrix.homeserver_url", "https://matrix.example.com", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("channels.matrix.allowed_room_ids", ["!room:example.com"], %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put(
               "channels.matrix.identity_map",
               [%{external_user_id: "@alice:example.com", user_id: "alice"}],
               %{audit?: false}
             )

    assert {:ok, _setting} = Settings.put("channels.matrix.enabled", true, %{audit?: false})

    Mix.Task.reenable("allbert.channels")

    matrix_ready =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["setup-check", "matrix"])
      end)

    assert matrix_ready =~ "matrix setup status=ready"
    assert matrix_ready =~ "missing=none"
    assert matrix_ready =~ "automatic_provider_retry=false"
    refute matrix_ready =~ "matrix-secret"

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["whatsapp", "set-token", "whatsapp-secret"])
    end)

    assert {:ok, _secret} =
             Secrets.put_secret(
               "secret://channels/whatsapp/app_secret",
               "whatsapp-app-secret",
               %{audit?: false}
             )

    assert {:ok, _secret} =
             Secrets.put_secret(
               "secret://channels/whatsapp/webhook_verify_token",
               "whatsapp-verify-secret",
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.app_secret_ref",
               "secret://channels/whatsapp/app_secret",
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.webhook_verify_token_ref",
               "secret://channels/whatsapp/webhook_verify_token",
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.phone_number_id", "15551234567", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.waba_id", "waba-1", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.identity_map",
               [%{external_user_id: "+15550001111", user_id: "alice"}],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.webhook_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("channels.whatsapp.enabled", true, %{audit?: false})

    Mix.Task.reenable("allbert.channels")

    whatsapp_ready =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["setup-check", "whatsapp"])
      end)

    # WhatsApp is intentionally release-gated: the Cloud API adapter was
    # implemented in v0.53 but not released for live channel use (Meta
    # provider-blocked), so a fully-configured whatsapp reports
    # `implemented_not_released`, not `ready`. All config/secrets are present.
    assert whatsapp_ready =~ "whatsapp setup status=implemented_not_released"
    assert whatsapp_ready =~ "missing=implemented_not_released"
    assert whatsapp_ready =~ "mix allbert.test external-smoke -- whatsapp"
    refute whatsapp_ready =~ "whatsapp-secret"
    refute whatsapp_ready =~ "15551234567"

    aci = "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001"
    local_aci = "5c4e9f85-f2a7-4f58-a0d8-2a6f4b4d8001"

    assert {:ok, _setting} =
             Settings.put("channels.signal.account_identifier", "+15551234567", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.signal.local_aci", local_aci, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.signal.identity_map",
               [%{external_user_id: aci, user_id: "alice"}],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("channels.signal.allowed_aci_ids", [aci], %{audit?: false})

    assert {:ok, _setting} = Settings.put("channels.signal.enabled", true, %{audit?: false})

    Mix.Task.reenable("allbert.channels")

    signal_ready =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["setup-check", "signal"])
      end)

    # Signal, like WhatsApp, is intentionally release-gated: the signal-cli
    # JSON-RPC bridge was implemented in v0.53 but not released for live channel
    # use (operator-managed daemon/link-device onboarding), so a fully-configured
    # signal reports `implemented_not_released`, not `ready`.
    assert signal_ready =~ "signal setup status=implemented_not_released"
    assert signal_ready =~ "missing=implemented_not_released"
    assert signal_ready =~ "mix allbert.test external-smoke -- signal"
    assert signal_ready =~ "pair=mix allbert.channels signal link --account <account>"
    refute signal_ready =~ "+15551234567"
  end

  test "stores credentials without printing secret values" do
    telegram_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["telegram", "set-token", "tg-secret"])
      end)

    assert telegram_output =~ "telegram bot_token=stored"
    refute telegram_output =~ "tg-secret"
    assert Secrets.status("secret://channels/telegram/bot_token") == :configured

    Mix.Task.reenable("allbert.channels")

    email_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["email", "set-password", "--type", "imap", "imap-secret"])
      end)

    assert email_output =~ "email imap_password=stored"
    refute email_output =~ "imap-secret"
    assert Secrets.status("secret://channels/email/imap_password") == :configured

    Mix.Task.reenable("allbert.channels")

    email_smtp_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run(["email", "set-password", "--type", "smtp", "smtp-secret"])
      end)

    assert email_smtp_output =~ "email smtp_password=stored"
    refute email_smtp_output =~ "smtp-secret"
    assert Secrets.status("secret://channels/email/smtp_password") == :configured

    Mix.Task.reenable("allbert.channels")

    matrix_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["matrix", "set-token", "matrix-secret"])
      end)

    assert matrix_output =~ "matrix access_token=stored"
    refute matrix_output =~ "matrix-secret"
    assert Secrets.status("secret://channels/matrix/access_token") == :configured

    Mix.Task.reenable("allbert.channels")

    whatsapp_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["whatsapp", "set-token", "whatsapp-secret"])
      end)

    assert whatsapp_output =~ "whatsapp access_token=stored"
    refute whatsapp_output =~ "whatsapp-secret"
    assert Secrets.status("secret://channels/whatsapp/access_token") == :configured

    Mix.Task.reenable("allbert.channels")

    discord_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "discord",
                   "set-token",
                   "secret://channels/discord/bot_token"
                 ])
      end)

    assert discord_output =~ "discord bot_token_ref=stored"

    assert {:ok, user_settings} = Settings.read_user_settings()

    assert get_in(user_settings, ["channels", "discord", "bot_token_ref"]) ==
             "secret://channels/discord/bot_token"

    Mix.Task.reenable("allbert.channels")

    slack_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "slack",
                   "set-token",
                   "secret://channels/slack/bot_token"
                 ])
      end)

    assert slack_output =~ "slack bot_token_ref=stored"

    Mix.Task.reenable("allbert.channels")

    slack_app_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "slack",
                   "set-app-token",
                   "secret://channels/slack/app_token"
                 ])
      end)

    assert slack_app_output =~ "slack app_token_ref=stored"

    assert {:ok, user_settings} = Settings.read_user_settings()

    assert get_in(user_settings, ["channels", "slack", "bot_token_ref"]) ==
             "secret://channels/slack/bot_token"

    assert get_in(user_settings, ["channels", "slack", "app_token_ref"]) ==
             "secret://channels/slack/app_token"
  end

  test "channel doctor commands return redacted envelopes" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/account/whoami"
      json(conn, %{"user_id" => "@allbert:example.com", "device_id" => "DEVICE"})
    end)

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["telegram", "set-token", "tg-secret"])
    end)

    Mix.Task.reenable("allbert.channels")

    telegram_doctor =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["telegram", "doctor"])
      end)

    assert telegram_doctor =~ "telegram doctor status=ok"
    assert telegram_doctor =~ "poller="
    refute telegram_doctor =~ "tg-secret"

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["email", "set-password", "--type", "imap", "imap-secret"])
    end)

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["email", "set-password", "--type", "smtp", "smtp-secret"])
    end)

    assert {:ok, _setting} =
             Settings.put("channels.email.imap_host", "imap.example.com", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.email.smtp_host", "smtp.example.com", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.email.imap_username", "alice", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.email.smtp_username", "alice", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.email.from_address", "allbert@example.com", %{audit?: false})

    Mix.Task.reenable("allbert.channels")

    email_doctor =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["email", "doctor"])
      end)

    assert email_doctor =~ "email doctor status=ok"
    assert email_doctor =~ "imap=true"
    assert email_doctor =~ "smtp=true"
    refute email_doctor =~ "imap-secret"
    refute email_doctor =~ "smtp-secret"

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["matrix", "set-token", "matrix-secret"])
    end)

    assert {:ok, _setting} =
             Settings.put("channels.matrix.homeserver_url", "https://matrix.example.com", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("channels.matrix.allowed_room_ids", ["!room:example.com"], %{
               audit?: false
             })

    Mix.Task.reenable("allbert.channels")

    matrix_doctor =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["matrix", "doctor"])
      end)

    assert matrix_doctor =~ "matrix doctor status=ok"
    assert matrix_doctor =~ "user=@allbert:example.com"
    assert matrix_doctor =~ "rooms=1"
    refute matrix_doctor =~ "matrix-secret"

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["whatsapp", "set-token", "whatsapp-secret"])
    end)

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.phone_number_id", "15551234567", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.identity_map",
               [%{external_user_id: "+15550001111", user_id: "alice"}],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.webhook_enabled", true, %{audit?: false})

    Mix.Task.reenable("allbert.channels")

    whatsapp_doctor =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["whatsapp", "doctor"])
      end)

    # Release-gated (see setup-check note above): the doctor reports
    # `implemented_not_released` rather than `ok` for the parked provider.
    assert whatsapp_doctor =~ "whatsapp doctor status=implemented_not_released"
    assert whatsapp_doctor =~ "adapter="
    refute whatsapp_doctor =~ "whatsapp-secret"
    refute whatsapp_doctor =~ "+15551234567"

    Mix.Task.reenable("allbert.channels")

    assert {:ok, _setting} =
             Settings.put("channels.signal.account_identifier", "+15551234567", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.signal.local_aci",
               "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001",
               %{audit?: false}
             )

    assert {:ok, _setting} = Settings.put("channels.signal.enabled", true, %{audit?: false})

    signal_doctor =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["signal", "doctor"])
      end)

    # Release-gated (see setup-check note above): the doctor returns the gated
    # envelope (`implemented_not_released`, `local_only=false`) rather than a live
    # `ok`/`local_only=true` result for the parked provider.
    assert signal_doctor =~ "signal doctor status=implemented_not_released"
    assert signal_doctor =~ "control=socket"
    assert signal_doctor =~ "local_only=false"
    refute signal_doctor =~ "+15551234567"
  end

  test "rejects raw Discord credentials" do
    assert_raise Mix.Error, ~r/secret:\/\/channels\/discord/, fn ->
      capture_io(fn ->
        ChannelsTask.run(["discord", "set-token", "RAW_DISCORD_TOKEN"])
      end)
    end
  end

  test "rejects raw Slack credentials" do
    assert_raise Mix.Error, ~r/secret:\/\/channels\/slack/, fn ->
      capture_io(fn ->
        ChannelsTask.run(["slack", "set-token", "xoxb-raw-token"])
      end)
    end

    Mix.Task.reenable("allbert.channels")

    assert_raise Mix.Error, ~r/secret:\/\/channels\/slack/, fn ->
      capture_io(fn ->
        ChannelsTask.run(["slack", "set-app-token", "xapp-raw-token"])
      end)
    end
  end

  test "manages explicit cross-channel identity links" do
    add_slack_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "identity-links",
                   "add",
                   "--link",
                   "link_alice",
                   "--channel",
                   "slack",
                   "--receiver",
                   "slack:team:T0123ABCDE",
                   "--external-user",
                   "U0123ABCDE",
                   "--user",
                   "alice"
                 ])
      end)

    assert add_slack_output =~ "linked link_alice user=alice channel=slack"
    assert add_slack_output =~ "receiver=slack:team:T0123ABCDE"

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "identity-links",
                 "add",
                 "--link",
                 "link_alice",
                 "--channel",
                 "discord",
                 "--receiver",
                 "discord:app:123456:guild:987654321",
                 "--external-user",
                 "11111",
                 "--user",
                 "alice"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    list_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["identity-links", "list", "--link", "link_alice"])
      end)

    assert list_output =~ "link link_alice user=alice channel=discord"
    assert list_output =~ "link link_alice user=alice channel=slack"

    Mix.Task.reenable("allbert.channels")

    remove_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "identity-links",
                   "remove",
                   "--link",
                   "link_alice",
                   "--channel",
                   "slack",
                   "--receiver",
                   "slack:team:T0123ABCDE",
                   "--external-user",
                   "U0123ABCDE"
                 ])
      end)

    assert remove_output =~ "unlinked link_alice user=alice channel=slack"

    Mix.Task.reenable("allbert.channels")

    list_after_remove =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["identity-links", "list", "--link", "link_alice"])
      end)

    assert list_after_remove =~ "link link_alice user=alice channel=discord"
    refute list_after_remove =~ "channel=slack"
  end

  test "M9 channel identity links never auto-merge provider identity maps" do
    for {channel, receiver, external_user} <- [
          {"matrix", "matrix:homeserver:example:room:!room:example.com", "@alice:example.com"},
          {"whatsapp", "whatsapp:waba:waba-1:phone:[REDACTED_PHONE]", "+15550001111"},
          {"signal", "signal:account:local-aci", "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001"}
        ] do
      Mix.Task.reenable("allbert.channels")

      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "identity-links",
                   "add",
                   "--link",
                   "link_alice_m9",
                   "--channel",
                   channel,
                   "--receiver",
                   receiver,
                   "--external-user",
                   external_user,
                   "--user",
                   "alice"
                 ])
      end)
    end

    Mix.Task.reenable("allbert.channels")

    list_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["identity-links", "list", "--link", "link_alice_m9"])
      end)

    assert list_output =~ "channel=matrix"
    assert list_output =~ "channel=whatsapp"
    assert list_output =~ "channel=signal"

    assert {:ok, matrix_map} = Settings.get("channels.matrix.identity_map")
    assert {:ok, whatsapp_map} = Settings.get("channels.whatsapp.identity_map")
    assert {:ok, signal_map} = Settings.get("channels.signal.identity_map")

    assert matrix_map == []
    assert whatsapp_map == []
    assert signal_map == []

    assert Identity.resolve("matrix", "@alice:example.com", matrix_map) == {:error, :not_mapped}
    assert Identity.resolve("whatsapp", "+15550001111", whatsapp_map) == {:error, :not_mapped}

    assert Identity.resolve(
             "signal",
             "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001",
             signal_map
           ) == {:error, :not_mapped}
  end

  test "maps identities and simulates both channels without provider access" do
    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "telegram",
                 "map",
                 "--external-user",
                 "123",
                 "--user",
                 "alice"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    telegram_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "telegram",
                   "simulate",
                   "--external-user",
                   "123",
                   "--chat",
                   "456",
                   "/new hello"
                 ])
      end)

    assert telegram_output =~ "status=processed"
    assert telegram_output =~ "User: alice"
    assert telegram_output =~ "Task channel response: hello"
    assert_received {:runtime_request, %{channel: "telegram", text: "hello"}}

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "email",
                 "map",
                 "--external-user",
                 "alice@example.com",
                 "--user",
                 "alice"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    seed_email_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "email",
                   "simulate",
                   "--external-user",
                   "alice@example.com",
                   "email seed"
                 ])
      end)

    assert seed_email_output =~ "status=processed"
    assert seed_email_output =~ "Task channel response: email seed"
    assert_received {:runtime_request, %{channel: "email", text: "email seed"}}

    Mix.Task.reenable("allbert.channels")

    new_thread_email_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "email",
                   "simulate",
                   "--external-user",
                   "alice@example.com",
                   "--new-thread",
                   "email hello"
                 ])
      end)

    assert new_thread_email_output =~ "status=processed"
    assert new_thread_email_output =~ "Task channel response: email hello"
    assert_received {:runtime_request, %{channel: "email", text: "email hello"}}

    email_threads =
      Event
      |> where([event], event.channel == "email")
      |> order_by([event], asc: event.inserted_at)
      |> select([event], event.thread_id)
      |> Repo.all()

    assert length(Enum.uniq(email_threads)) == 2
    assert Repo.aggregate(Event, :count) == 3

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "discord",
                 "set-token",
                 "secret://channels/discord/bot_token"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["discord", "set-application-id", "123456"])
    end)

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["discord", "add-guild", "987654321"])
    end)

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["discord", "add-channel", "22222"])
    end)

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "discord",
                 "map",
                 "--external-user",
                 "11111",
                 "--user",
                 "alice"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    assert {:ok, _setting} = Settings.put("channels.discord.enabled", true, %{audit?: false})

    discord_doctor =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["discord", "doctor"])
      end)

    assert discord_doctor =~ "discord doctor status=ok"
    refute discord_doctor =~ "Bot "

    Mix.Task.reenable("allbert.channels")

    discord_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "discord",
                   "simulate",
                   "--guild",
                   "987654321",
                   "--channel",
                   "22222",
                   "--user",
                   "11111",
                   "discord hello"
                 ])
      end)

    assert discord_output =~ "status=processed"
    assert discord_output =~ "User: alice"
    assert discord_output =~ "Task channel response: discord hello"
    assert_received {:runtime_request, %{channel: "discord", text: "discord hello"}}

    Mix.Task.reenable("allbert.channels")

    assert {:ok, confirmation} =
             Confirmations.create(%{
               origin: %{actor: "alice", channel: :discord, surface: "mix allbert.channels"},
               target_action: %{name: "write_note"},
               target_permission: :notes_file_write,
               target_execution_mode: :notes_file_write,
               security_decision: %{permission: :notes_file_write, decision: :needs_confirmation},
               params_summary: %{title: "discord callback"}
             })

    discord_callback_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "discord",
                   "simulate-callback",
                   "--user",
                   "11111",
                   "--custom-id",
                   "allbert:v1:deny:#{confirmation["id"]}"
                 ])
      end)

    assert discord_callback_output =~ "status=processed"
    assert discord_callback_output =~ "denied"
    refute discord_callback_output =~ "missing token"
    assert {:ok, resolved} = Confirmations.read(confirmation["id"])
    assert resolved["status"] == "denied"

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "slack",
                 "set-token",
                 "secret://channels/slack/bot_token"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "slack",
                 "set-app-token",
                 "secret://channels/slack/app_token"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["slack", "set-team-id", "T0123ABCDE"])
    end)

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["slack", "add-channel", "C0123ABCDE"])
    end)

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "slack",
                 "map",
                 "--external-user",
                 "U0123ABCDE",
                 "--user",
                 "alice"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    assert {:ok, _setting} = Settings.put("channels.slack.enabled", true, %{audit?: false})

    slack_doctor =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["slack", "doctor"])
      end)

    assert slack_doctor =~ "slack doctor status=ok"
    refute slack_doctor =~ "Bearer "

    Mix.Task.reenable("allbert.channels")

    slack_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "slack",
                   "simulate",
                   "--channel",
                   "C0123ABCDE",
                   "--user",
                   "U0123ABCDE",
                   "slack hello"
                 ])
      end)

    assert slack_output =~ "status=processed"
    assert slack_output =~ "User: alice"
    assert slack_output =~ "Task channel response: slack hello"
    assert_received {:runtime_request, %{channel: "slack", text: "slack hello"}}

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "matrix",
                 "map",
                 "--external-user",
                 "@alice:example.com",
                 "--user",
                 "alice"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    matrix_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "matrix",
                   "simulate",
                   "--room",
                   "!room:example.com",
                   "--user",
                   "@alice:example.com",
                   "matrix hello"
                 ])
      end)

    assert matrix_output =~ "status=processed"
    assert matrix_output =~ "User: alice"
    assert matrix_output =~ "Task channel response: matrix hello"
    assert_received {:runtime_request, %{channel: "matrix", text: "matrix hello"}}

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok = ChannelsTask.run(["whatsapp", "set-token", "whatsapp-secret"])
    end)

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.phone_number_id", "15551234567", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.enabled", true, %{audit?: false})

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "whatsapp",
                 "map",
                 "--external-user",
                 "+15550001111",
                 "--user",
                 "alice"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    whatsapp_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "whatsapp",
                   "simulate",
                   "--from",
                   "+15550001111",
                   "whatsapp hello"
                 ])
      end)

    assert whatsapp_output =~ "status=processed"
    assert whatsapp_output =~ "User: alice"
    assert whatsapp_output =~ "whatsapp processed=1"
    assert_received {:runtime_request, %{channel: "whatsapp", text: "whatsapp hello"}}

    Mix.Task.reenable("allbert.channels")

    whatsapp_button_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "whatsapp",
                   "simulate-button",
                   "--from",
                   "+15550001111",
                   "--button-id",
                   "allbert:v1:approve:missing_confirmation"
                 ])
      end)

    assert whatsapp_button_output =~ "whatsapp poll_once:"
    assert whatsapp_button_output =~ "rejected: 1"

    Mix.Task.reenable("allbert.channels")

    assert {:ok, _setting} =
             Settings.put("channels.signal.account_identifier", "+15551234567", %{audit?: false})

    assert {:ok, _setting} = Settings.put("channels.signal.enabled", true, %{audit?: false})

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "signal",
                 "map",
                 "--aci",
                 "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001",
                 "--user",
                 "alice"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    signal_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "signal",
                   "simulate",
                   "--aci",
                   "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001",
                   "signal hello"
                 ])
      end)

    assert signal_output =~ "status=processed"
    assert signal_output =~ "User: alice"
    assert signal_output =~ "signal processed=1"
    assert_received {:runtime_request, %{channel: "signal", text: "signal hello"}}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)

  defp json(conn, body) do
    status = conn.status || 200

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
