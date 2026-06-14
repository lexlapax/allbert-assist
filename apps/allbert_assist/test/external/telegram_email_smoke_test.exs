defmodule AllbertAssist.External.TelegramEmailSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial
  @moduletag :home_fs_serial

  if System.get_env("ALLBERT_TELEGRAM_EMAIL_EXTERNAL_SMOKE") != "1" do
    @moduletag skip:
                 "set ALLBERT_TELEGRAM_EMAIL_EXTERNAL_SMOKE=1 to run the real Telegram/email delivery smoke"
  end

  alias AllbertAssist.Channels.Email.SmtpClient
  alias AllbertAssist.Channels.Telegram.Client, as: TelegramClient
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets

  @telegram_required ["ALLBERT_TELEGRAM_BOT_TOKEN", "ALLBERT_TELEGRAM_CHAT_ID"]
  @email_required [
    "ALLBERT_EMAIL_SMTP_HOST",
    "ALLBERT_EMAIL_SMTP_PORT",
    "ALLBERT_EMAIL_SMTP_USERNAME",
    "ALLBERT_EMAIL_SMTP_PASSWORD",
    "ALLBERT_EMAIL_FROM_ADDRESS",
    "ALLBERT_EMAIL_TO_ADDRESS"
  ]

  setup_all do
    providers = targeted_providers()

    required =
      if("telegram" in providers, do: @telegram_required, else: []) ++
        if "email" in providers, do: @email_required, else: []

    missing = Enum.filter(required, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      flunk(
        "missing required Telegram/email delivery smoke env vars for providers #{inspect(providers)}: #{Enum.join(missing, ", ")}"
      )
    end

    home =
      System.get_env("ALLBERT_HOME") ||
        Path.join(System.tmp_dir!(), "allbert-telegram-email-smoke")

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_plugins = PluginRegistry.registered_plugins()

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    PluginRegistry.clear()

    if "telegram" in providers,
      do: {:ok, _} = PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)

    if "email" in providers,
      do: {:ok, _} = PluginRegistry.register_module(AllbertAssist.Plugins.Email)

    Fragments.clear_cache()

    Mix.Task.reenable("ecto.migrate.allbert")
    Mix.Task.run("ecto.migrate.allbert", ["--quiet"])

    if "telegram" in providers do
      put_secret!(
        "secret://channels/telegram/bot_token",
        System.fetch_env!("ALLBERT_TELEGRAM_BOT_TOKEN")
      )
    end

    if "email" in providers do
      put_secret!(
        "secret://channels/email/smtp_password",
        System.fetch_env!("ALLBERT_EMAIL_SMTP_PASSWORD")
      )
    end

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
    end)

    %{
      home: home,
      providers: providers,
      telegram_token: System.get_env("ALLBERT_TELEGRAM_BOT_TOKEN"),
      telegram_chat_id: System.get_env("ALLBERT_TELEGRAM_CHAT_ID"),
      email_smtp_host: System.get_env("ALLBERT_EMAIL_SMTP_HOST"),
      email_smtp_port: System.get_env("ALLBERT_EMAIL_SMTP_PORT"),
      email_smtp_username: System.get_env("ALLBERT_EMAIL_SMTP_USERNAME"),
      email_smtp_password: System.get_env("ALLBERT_EMAIL_SMTP_PASSWORD"),
      email_from_address: System.get_env("ALLBERT_EMAIL_FROM_ADDRESS"),
      email_to_address: System.get_env("ALLBERT_EMAIL_TO_ADDRESS"),
      email_smtp_tls: System.get_env("ALLBERT_EMAIL_SMTP_TLS", "true")
    }
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "real Telegram and email delivery preserve thread metadata", context do
    started_at = DateTime.utc_now()
    marker = "Allbert v0.53 delivery smoke #{DateTime.to_iso8601(started_at)}"

    assert {:ok, thread} = Conversations.create_general_thread("external-smoke", "v0.53 smoke")

    telegram_evidence =
      if "telegram" in context.providers,
        do: smoke_telegram(context, thread, marker),
        else: :skipped

    email_evidence =
      if "email" in context.providers, do: smoke_email(context, thread, marker), else: :skipped

    evidence_path =
      write_evidence!(context.home, started_at, %{
        providers: context.providers,
        telegram: telegram_evidence,
        email: email_evidence
      })

    IO.puts("telegram_email external smoke evidence: #{evidence_path}")
  end

  defp smoke_telegram(context, thread, marker) do
    assert {:ok, bot} = TelegramClient.get_me(context.telegram_token, mode: :real)

    assert {:ok, parent} =
             TelegramClient.send_message(
               context.telegram_token,
               context.telegram_chat_id,
               "#{marker} Telegram parent"
             )

    parent_message_id = Map.fetch!(parent, "message_id")

    assert {:ok, reply} =
             TelegramClient.send_message(
               context.telegram_token,
               context.telegram_chat_id,
               "#{marker} Telegram reply",
               reply_to_message_id: parent_message_id
             )

    assert {:ok, assistant} = Conversations.append_assistant_message(thread, "Telegram sent")

    receiver = telegram_receiver(context.telegram_chat_id)

    assert {:ok, _ref} =
             ChannelThread.record_message_ref(%{
               channel: "telegram",
               receiver_account_ref: receiver,
               provider_thread_ref: %{
                 provider: "telegram",
                 chat_id: context.telegram_chat_id,
                 provider_thread_root: "message:#{parent_message_id}"
               },
               canonical_thread_id: thread.id,
               canonical_message_id: assistant.id,
               provider_message_id: Map.fetch!(reply, "message_id"),
               direction: :out
             })

    assert ChannelThread.echo?(%{
             channel: "telegram",
             receiver_account_ref: receiver,
             provider_message_id: Map.fetch!(reply, "message_id")
           })

    %{
      bot_id: Map.get(bot, "id"),
      bot_username: Map.get(bot, "username"),
      chat_id: context.telegram_chat_id,
      parent_message_id: parent_message_id,
      reply_message_id: Map.fetch!(reply, "message_id"),
      echo_suppression_recorded?: true
    }
  end

  defp smoke_email(context, thread, marker) do
    message_id = "#{Ecto.UUID.generate()}@allbert.local"
    subject = "Allbert v0.53 external smoke"
    body = "#{marker}\n\nEmail delivery smoke."

    assert :ok =
             SmtpClient.send(
               context.email_from_address,
               context.email_to_address,
               subject,
               body,
               host: context.email_smtp_host,
               port: String.to_integer(context.email_smtp_port),
               username: context.email_smtp_username,
               password: context.email_smtp_password,
               tls: parse_bool(context.email_smtp_tls),
               from_name: "Allbert",
               message_id: message_id
             )

    assert {:ok, assistant} = Conversations.append_assistant_message(thread, "Email sent")
    receiver = email_receiver(context.email_from_address)

    assert {:ok, _ref} =
             ChannelThread.record_message_ref(%{
               channel: "email",
               receiver_account_ref: receiver,
               provider_thread_ref: %{
                 provider: "email",
                 mailbox: receiver,
                 provider_thread_root: message_id,
                 message_id: message_id,
                 subject: subject
               },
               canonical_thread_id: thread.id,
               canonical_message_id: assistant.id,
               provider_message_id: message_id,
               direction: :out
             })

    assert ChannelThread.echo?(%{
             channel: "email",
             receiver_account_ref: receiver,
             provider_message_id: message_id
           })

    %{
      from_address: context.email_from_address,
      to_address: context.email_to_address,
      message_id: message_id,
      echo_suppression_recorded?: true
    }
  end

  defp targeted_providers do
    case System.get_env("ALLBERT_SMOKE_PROVIDERS") do
      value when value in [nil, ""] ->
        ["telegram", "email"]

      value ->
        value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp write_evidence!(home, started_at, provider_evidence) do
    evidence_dir = Path.join(home, "release_evidence/v053")
    File.mkdir_p!(evidence_dir)
    provider_slug = Enum.join(provider_evidence.providers, "-")

    evidence = %{
      gate: "mix allbert.test external-smoke -- #{Enum.join(provider_evidence.providers, "_")}",
      version: "v0.53",
      status: "passed",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      providers: provider_evidence,
      secret_material:
        "redacted; tokens and passwords stored only through Settings Central secret refs"
    }

    path =
      Path.join(
        evidence_dir,
        "external-smoke-#{provider_slug}-#{DateTime.to_unix(started_at)}.json"
      )

    File.write!(path, Jason.encode!(evidence, pretty: true))
    path
  end

  defp telegram_receiver(chat_id) do
    bot_ref = ChannelThread.provider_thread_key("secret://channels/telegram/bot_token")
    "telegram:bot:#{bot_ref}:chat:#{chat_id}"
  end

  defp email_receiver(from_address), do: "email:mailbox:#{String.downcase(from_address)}"

  defp parse_bool(value) when value in [true, "true", "1", "yes"], do: true
  defp parse_bool(_value), do: false

  defp put_secret!(secret_ref, value) do
    assert {:ok, _secret} = Secrets.put_secret(secret_ref, value, %{audit?: false})
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
