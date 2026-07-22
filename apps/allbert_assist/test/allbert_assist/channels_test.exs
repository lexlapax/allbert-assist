defmodule AllbertAssist.ChannelsTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureLog

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.LocalSurface
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Discord, as: DiscordPlugin
  alias AllbertAssist.Plugins.Email, as: EmailPlugin
  alias AllbertAssist.Plugins.Slack, as: SlackPlugin
  alias AllbertAssist.Plugins.Telegram, as: TelegramPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments

  setup do
    ensure_default_channel_plugins()
    :ok
  end

  test "channel child specs honor launch-time exclusions" do
    ids =
      Channels.channel_child_specs(exclude_channels: ["tui"])
      |> Enum.map(& &1.id)

    refute "tui" in ids
    assert "tui" in Enum.map(Channels.channel_child_specs(), & &1.id)
  end

  describe "channel events" do
    test "creates and updates durable events" do
      assert {:ok, %Event{} = event} =
               Channels.create_event(%{
                 channel: "telegram",
                 provider: "telegram_bot_api",
                 direction: "inbound",
                 external_event_id: "100",
                 external_user_id: "123",
                 status: "received",
                 payload_summary: String.duplicate("x", 700)
               })

      assert event.payload_summary == String.duplicate("x", 500)

      assert {:ok, updated} =
               Channels.update_event(event, %{
                 status: "processed",
                 user_id: "alice",
                 thread_id: "thread_1",
                 trace_id: "trace_1"
               })

      assert updated.status == "processed"
      assert updated.user_id == "alice"
      assert updated.thread_id == "thread_1"
      assert updated.trace_id == "trace_1"
    end

    test "redacts phone numbers before channel events are persisted" do
      assert {:ok, %Event{} = event} =
               Channels.create_event(%{
                 channel: "signal",
                 provider: "signal_cli",
                 direction: "inbound",
                 external_event_id: "signal-phone-redaction",
                 external_user_id: "+15551234567",
                 external_chat_id: "signal:+15557654321",
                 external_message_id: "msg:+442071838750",
                 status: "received",
                 payload_summary: "from +15551234567"
               })

      assert event.external_user_id == "[REDACTED_PHONE]"
      assert event.external_chat_id == "signal:[REDACTED_PHONE]"
      assert event.external_message_id == "msg:[REDACTED_PHONE]"
      assert event.payload_summary == "from [REDACTED_PHONE]"

      persisted = Repo.get!(Event, event.id)
      refute inspect(persisted) =~ "+15551234567"
      refute inspect(persisted) =~ "+15557654321"
      refute inspect(persisted) =~ "+442071838750"
    end

    test "dedupes inbound and callback provider events by channel and external id" do
      attrs = %{
        channel: "telegram",
        provider: "telegram_bot_api",
        direction: "inbound",
        external_event_id: "101",
        status: "received"
      }

      assert {:ok, _event} = Channels.create_event(attrs)
      assert {:error, %Ecto.Changeset{}} = Channels.create_event(attrs)

      assert {:ok, _event} =
               Channels.create_event(%{
                 attrs
                 | direction: "outbound",
                   external_event_id: "101"
               })
    end

    test "emits channel lifecycle signals from durable event state changes" do
      original_logger_level = Logger.level()
      Logger.configure(level: :info)

      log =
        try do
          capture_log([level: :info], fn ->
            assert {:ok, inbound} =
                     Channels.create_event(%{
                       channel: "telegram",
                       provider: "telegram_bot_api",
                       direction: "inbound",
                       external_event_id: "signal-inbound",
                       external_user_id: "123",
                       status: "received"
                     })

            assert {:ok, _event} =
                     Channels.update_event(inbound, %{
                       status: "processed",
                       user_id: "alice",
                       session_id: "ch_tg_signal",
                       thread_id: "thr_signal",
                       trace_id: "trace_signal",
                       input_signal_id: "sig_signal"
                     })

            assert {:ok, _callback} =
                     Channels.create_event(%{
                       channel: "email",
                       provider: "email_imap",
                       direction: "callback",
                       external_event_id: "signal-callback",
                       external_user_id: "alice@example.com",
                       status: "received"
                     })

            assert {:ok, _rejected} =
                     Channels.create_event(%{
                       channel: "email",
                       provider: "email_imap",
                       direction: "inbound",
                       external_event_id: "signal-rejected",
                       status: "rejected",
                       reason: ":not_mapped"
                     })

            assert {:ok, failed} =
                     Channels.create_event(%{
                       channel: "email",
                       provider: "email_imap",
                       direction: "outbound",
                       external_event_id: "signal-failed",
                       status: "received"
                     })

            assert {:ok, _event} =
                     Channels.update_event(failed, %{
                       status: "failed",
                       error: "smtp unavailable"
                     })
          end)
        after
          Logger.configure(level: original_logger_level)
        end

      assert log =~ "allbert.channel.update_received"
      assert log =~ "allbert.channel.runtime_submitted"
      assert log =~ "allbert.channel.response_sent"
      assert log =~ "allbert.channel.callback_received"
      assert log =~ "allbert.channel.message_rejected"
      assert log =~ "allbert.channel.delivery_failed"
    end

    test "returns max inbound integer event id for Telegram offset derivation" do
      for id <- ["10", "12", "not-an-int"] do
        assert {:ok, _event} =
                 Channels.create_event(%{
                   channel: "telegram",
                   provider: "telegram_bot_api",
                   direction: "inbound",
                   external_event_id: id,
                   status: "received"
                 })
      end

      assert Channels.max_inbound_integer_event_id("telegram") == 12
      assert Channels.max_inbound_integer_event_id("email") == 0
    end

    test "generates outbound event ids" do
      assert {:ok, event} =
               Channels.create_event(%{
                 channel: "email",
                 provider: "email_smtp",
                 direction: "outbound",
                 status: "processed"
               })

      assert String.starts_with?(event.external_event_id, "out_")
      assert Repo.get!(Event, event.id)
    end
  end

  describe "identity resolution" do
    test "resolves mapped identities and rejects disabled or unknown identities" do
      identity_map = [
        %{"external_user_id" => "123", "user_id" => "alice"},
        %{"external_user_id" => "bob@example.com", "user_id" => "bob", "enabled" => false}
      ]

      assert Identity.resolve("telegram", "123", identity_map) == {:ok, "alice"}
      assert Identity.resolve("email", "BOB@example.com", identity_map) == {:error, :disabled}
      assert Identity.resolve("telegram", "999", identity_map) == {:error, :not_mapped}
    end

    test "does not fall back to local" do
      assert Identity.resolve("telegram", "123", []) == {:error, :not_mapped}
    end
  end

  describe "session ids" do
    test "derives stable bounded provider-specific session ids" do
      telegram = Channels.derive_session_id("telegram", "123", "456")
      email = Channels.derive_session_id("email", "alice@example.com", nil)

      assert telegram == Channels.derive_session_id("telegram", "123", "456")
      assert email == Channels.derive_session_id("email", "alice@example.com", nil)
      assert String.starts_with?(telegram, "ch_tg_")
      assert String.starts_with?(email, "ch_em_")
      assert String.length(telegram) == 38
      assert String.length(email) == 38
      refute telegram =~ "123"
      refute email =~ "alice"
    end

    test "provider thread roots participate in session derivation without leaking ids" do
      root_a = "T1:C1:thread-a"
      root_b = "T1:C1:thread-b"

      slack_a = Channels.derive_session_id("slack", "U123", root_a)
      slack_b = Channels.derive_session_id("slack", "U123", root_b)

      assert slack_a == Channels.derive_session_id("slack", "U123", root_a)
      assert slack_a != slack_b
      assert String.starts_with?(slack_a, "ch_sl_")
      assert String.length(slack_a) == 38
      refute slack_a =~ "U123"
      refute slack_a =~ "thread-a"
    end
  end

  describe "channel descriptors" do
    test "registered channel plugins declare approval primitives and threading" do
      descriptors = Map.new(PluginRegistry.registered_channels(), &{&1.channel_id, &1})

      assert %{
               primitives: telegram_primitives,
               threading: :reply_chain,
               trust_class: :server_readable
             } =
               Map.fetch!(descriptors, "telegram")

      assert :button in telegram_primitives
      assert :typed_command in telegram_primitives
      assert :list in telegram_primitives

      assert %{
               primitives: email_primitives,
               threading: :reply_chain,
               trust_class: :server_readable
             } =
               Map.fetch!(descriptors, "email")

      refute :button in email_primitives
      assert :typed_command in email_primitives
      assert :list in email_primitives

      assert %{
               primitives: discord_primitives,
               threading: :native_threads,
               trust_class: :server_readable
             } =
               Map.fetch!(descriptors, "discord")

      assert :button in discord_primitives
      assert :typed_command in discord_primitives
      assert :list in discord_primitives

      assert %{
               primitives: slack_primitives,
               threading: :native_threads,
               trust_class: :server_readable
             } =
               Map.fetch!(descriptors, "slack")

      assert :button in slack_primitives
      assert :typed_command in slack_primitives
      assert :list in slack_primitives
    end

    test "local web and CLI surfaces declare rich threading without adapter authority" do
      descriptors =
        LocalSurface.descriptors()
        |> Map.new(&{&1.channel_id, &1})

      assert %{
               provider: "local_cli",
               primitives: cli_primitives,
               threading: :rich,
               trust_class: :local,
               receiver_account_ref: "cli:default"
             } = Map.fetch!(descriptors, "cli")

      assert :typed_command in cli_primitives
      assert :list in cli_primitives

      assert %{
               provider: "phoenix_live_view",
               primitives: web_primitives,
               threading: :rich,
               trust_class: :local,
               receiver_account_ref: "web:workspace"
             } = Map.fetch!(descriptors, "live_view")

      assert :button in web_primitives
      assert :typed_command in web_primitives
      assert :list in web_primitives
    end
  end

  describe "channel summaries" do
    setup do
      original_paths_config = Application.get_env(:allbert_assist, Paths)
      original_settings_config = Application.get_env(:allbert_assist, Settings)

      root =
        Path.join(
          System.tmp_dir!(),
          "allbert-channels-summary-test-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:allbert_assist, Paths, home: root)
      Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

      on_exit(fn ->
        restore_env(Paths, original_paths_config)
        restore_env(Settings, original_settings_config)
        File.rm_rf!(root)
      end)

      %{root: root}
    end

    test "lists channels when Settings Central returns an error", %{root: root} do
      settings_path = Path.join([root, "settings", "settings.yml"])
      File.mkdir_p!(Path.dirname(settings_path))
      File.write!(settings_path, "[not, a, map]\n")

      channels = Map.new(Channels.list_channels(), &{&1.channel, &1})
      telegram_status = channels["telegram"].credential_status
      email_status = channels["email"].credential_status
      discord_status = channels["discord"].credential_status
      slack_status = channels["slack"].credential_status

      assert telegram_status["channels.telegram.bot_token_ref"] == :missing
      assert email_status["channels.email.imap_password_ref"] == :missing
      assert email_status["channels.email.smtp_password_ref"] == :missing
      assert discord_status["channels.discord.bot_token_ref"] == :missing
      assert slack_status["channels.slack.bot_token_ref"] == :missing
      assert slack_status["channels.slack.app_token_ref"] == :missing
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp ensure_default_channel_plugins do
    _ = PluginRegistry.register_module(TelegramPlugin)
    _ = PluginRegistry.register_module(EmailPlugin)
    _ = PluginRegistry.register_module(DiscordPlugin)
    _ = PluginRegistry.register_module(SlackPlugin)
    Fragments.clear_cache()
  end
end
