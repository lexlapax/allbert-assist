defmodule AllbertAssist.External.TelegramEmailInboundSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial
  @moduletag timeout: :infinity

  if System.get_env("ALLBERT_TELEGRAM_EMAIL_INBOUND_EXTERNAL_SMOKE") != "1" do
    @moduletag skip:
                 "set ALLBERT_TELEGRAM_EMAIL_INBOUND_EXTERNAL_SMOKE=1 to run the real Telegram/email inbound smoke"
  end

  alias AllbertAssist.Channels.Email.Adapter, as: EmailAdapter
  alias AllbertAssist.Channels.Telegram.Adapter, as: TelegramAdapter
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Email, as: EmailPlugin
  alias AllbertAssist.Plugins.Telegram, as: TelegramPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace
  alias Ecto.Adapters.SQL.Sandbox

  @telegram_required [
    "ALLBERT_TELEGRAM_BOT_TOKEN",
    "ALLBERT_TELEGRAM_CHAT_ID",
    "ALLBERT_TELEGRAM_USER_ID"
  ]
  @email_required [
    "ALLBERT_EMAIL_IMAP_HOST",
    "ALLBERT_EMAIL_IMAP_PORT",
    "ALLBERT_EMAIL_IMAP_USERNAME",
    "ALLBERT_EMAIL_IMAP_PASSWORD",
    "ALLBERT_EMAIL_SMTP_HOST",
    "ALLBERT_EMAIL_SMTP_PORT",
    "ALLBERT_EMAIL_SMTP_USERNAME",
    "ALLBERT_EMAIL_SMTP_PASSWORD",
    "ALLBERT_EMAIL_FROM_ADDRESS",
    "ALLBERT_EMAIL_MAPPED_SENDER"
  ]

  setup_all do
    providers = targeted_providers()

    required =
      if("telegram" in providers, do: @telegram_required, else: []) ++
        if "email" in providers, do: @email_required, else: []

    missing = Enum.filter(required, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      flunk(
        "missing required Telegram/email inbound smoke env vars for providers #{inspect(providers)}: #{Enum.join(missing, ", ")}"
      )
    end

    home =
      System.get_env("ALLBERT_HOME") ||
        Path.join(System.tmp_dir!(), "allbert-telegram-email-inbound-smoke")

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    if "telegram" in providers, do: {:ok, _} = PluginRegistry.register_module(TelegramPlugin)
    if "email" in providers, do: {:ok, _} = PluginRegistry.register_module(EmailPlugin)
    Fragments.clear_cache()

    Mix.Task.reenable("ecto.migrate.allbert")
    Mix.Task.run("ecto.migrate.allbert", ["--quiet"])

    put_targeted_secrets!(providers)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
    end)

    %{
      home: home,
      providers: providers,
      timeout_ms: timeout_ms(providers),
      telegram_chat_id: System.get_env("ALLBERT_TELEGRAM_CHAT_ID"),
      telegram_user_id: System.get_env("ALLBERT_TELEGRAM_USER_ID"),
      email_from_address: System.get_env("ALLBERT_EMAIL_FROM_ADDRESS"),
      email_mapped_sender: System.get_env("ALLBERT_EMAIL_MAPPED_SENDER")
    }
  end

  setup do
    :ok = Sandbox.checkout(Repo, ownership_timeout: 3_600_000)
    Sandbox.mode(Repo, {:shared, self()})

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})
        {:ok, %{message: "Inbound smoke received: #{request.text}", status: :completed}}
      end
    )

    :ok
  end

  test "real Telegram long polling and email IMAP deliver operator-sent inbound messages",
       context do
    started_at = DateTime.utc_now()

    marker =
      case System.get_env("ALLBERT_SMOKE_MARKER") do
        value when value in [nil, ""] -> "allbert-v053-inbound-#{DateTime.to_unix(started_at)}"
        value -> value
      end

    telegram? = "telegram" in context.providers
    email? = "email" in context.providers

    telegram_adapter = if telegram?, do: start_telegram!(context), else: nil
    email_adapter = if email?, do: start_email!(context), else: nil

    print_marker_instructions(context, marker, telegram?, email?)

    expected_channels =
      [] ++ if(telegram?, do: ["telegram"], else: []) ++ if(email?, do: ["email"], else: [])

    requests =
      wait_for_runtime_requests(expected_channels, marker, context.timeout_ms, context.home)

    evidence_path =
      write_evidence!(context.home, started_at, %{
        marker: marker,
        providers: context.providers,
        timeout_ms: context.timeout_ms,
        telegram: provider_evidence("telegram", telegram_adapter, requests, context),
        email: provider_evidence("email", email_adapter, requests, context),
        manual_followups_required: [
          "Telegram inline approve/deny/show button from the mapped clicker",
          "email typed approve/deny/show command from the mapped sender",
          "unmapped sender rejection before runtime"
        ]
      })

    IO.puts("telegram_email_inbound external smoke evidence: #{evidence_path}")
  end

  defp start_telegram!(context) do
    put_setting!("channels.telegram.bot_token_ref", "secret://channels/telegram/bot_token")

    put_setting!("channels.telegram.identity_map", [
      %{
        "external_user_id" => context.telegram_user_id,
        "user_id" => "external-smoke",
        "enabled" => true
      }
    ])

    put_setting!("channels.telegram.allowed_chat_ids", [context.telegram_chat_id])
    put_setting!("channels.telegram.poll_interval_ms", 1000)
    put_setting!("channels.telegram.poll_timeout_seconds", 5)
    put_setting!("channels.telegram.enabled", true)

    assert {:ok, pid} = TelegramAdapter.start_link(name: nil)
    pid
  end

  defp start_email!(context) do
    put_setting!("channels.email.imap_host", System.fetch_env!("ALLBERT_EMAIL_IMAP_HOST"))

    put_setting!(
      "channels.email.imap_port",
      String.to_integer(System.fetch_env!("ALLBERT_EMAIL_IMAP_PORT"))
    )

    put_setting!(
      "channels.email.imap_ssl",
      parse_bool(System.get_env("ALLBERT_EMAIL_IMAP_SSL", "true"))
    )

    put_setting!("channels.email.imap_username", System.fetch_env!("ALLBERT_EMAIL_IMAP_USERNAME"))
    put_setting!("channels.email.imap_password_ref", "secret://channels/email/imap_password")

    put_setting!(
      "channels.email.imap_mailbox",
      System.get_env("ALLBERT_EMAIL_IMAP_MAILBOX", "INBOX")
    )

    put_setting!("channels.email.imap_poll_interval_ms", 5000)
    put_setting!("channels.email.smtp_host", System.fetch_env!("ALLBERT_EMAIL_SMTP_HOST"))

    put_setting!(
      "channels.email.smtp_port",
      String.to_integer(System.fetch_env!("ALLBERT_EMAIL_SMTP_PORT"))
    )

    put_setting!(
      "channels.email.smtp_tls",
      parse_bool(System.get_env("ALLBERT_EMAIL_SMTP_TLS", "true"))
    )

    put_setting!("channels.email.smtp_username", System.fetch_env!("ALLBERT_EMAIL_SMTP_USERNAME"))
    put_setting!("channels.email.smtp_password_ref", "secret://channels/email/smtp_password")
    put_setting!("channels.email.from_address", context.email_from_address)

    put_setting!("channels.email.identity_map", [
      %{
        "external_user_id" => context.email_mapped_sender,
        "user_id" => "external-smoke",
        "enabled" => true
      }
    ])

    put_setting!("channels.email.enabled", true)

    assert {:ok, pid} = EmailAdapter.start_link(name: nil)
    pid
  end

  defp print_marker_instructions(context, marker, telegram?, email?) do
    telegram_line =
      if telegram? do
        """
        Send from mapped Telegram user #{context.telegram_user_id} in chat #{context.telegram_chat_id}:
          #{marker} telegram
        """
      else
        ""
      end

    email_line =
      if email? do
        """
        Send from #{context.email_mapped_sender} to #{context.email_from_address}:
          Subject: Allbert v0.53 inbound smoke
          Body: #{marker} email
        """
      else
        ""
      end

    IO.puts("""
    telegram_email_inbound marker: #{marker}
    #{telegram_line}#{email_line}Waiting up to #{context.timeout_ms}ms for provider-delivered inbound events.
    """)
  end

  defp wait_for_runtime_requests(channels, marker, timeout_ms, home) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_runtime_requests(MapSet.new(channels), marker, deadline, %{}, home)
  end

  defp do_wait_for_runtime_requests(expected, marker, deadline, found, home) do
    if MapSet.size(expected) == 0 do
      found
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:runtime_request, request} ->
          if matching_request?(request, expected, marker) do
            channel = to_string(request.channel)

            do_wait_for_runtime_requests(
              MapSet.delete(expected, channel),
              marker,
              deadline,
              Map.put(found, channel, request),
              home
            )
          else
            do_wait_for_runtime_requests(expected, marker, deadline, found, home)
          end
      after
        remaining ->
          diag = dump_inbound_diagnostics(home)

          flunk(
            "timed out waiting for inbound runtime requests from " <>
              "#{inspect(MapSet.to_list(expected))}\n--- recorded channel_events ---\n#{diag}"
          )
      end
    end
  end

  defp matching_request?(request, expected, marker) do
    channel = to_string(Map.get(request, :channel))
    text = to_string(Map.get(request, :text))

    MapSet.member?(expected, channel) and String.contains?(text, marker)
  end

  defp dump_inbound_diagnostics(home) do
    import Ecto.Query

    rows =
      Repo.all(
        from(e in AllbertAssist.Channels.Event,
          order_by: [desc: e.inserted_at],
          limit: 20
        )
      )

    text =
      if rows == [] do
        "(none - no inbound channel_events recorded; check provider credentials, mapping, allowlists, and that the message reached the configured mailbox/chat)"
      else
        Enum.map_join(rows, "\n", fn e ->
          "#{e.inserted_at} channel=#{e.channel} dir=#{e.direction} " <>
            "status=#{e.status} ext_user=#{e.external_user_id} " <>
            "ext_chat=#{e.external_chat_id} reason=#{e.reason}"
        end)
      end

    path = Path.join(home, "inbound-diagnostics.txt")
    File.mkdir_p!(home)
    File.write!(path, text)
    IO.puts("inbound diagnostics written: #{path}")
    text
  end

  defp provider_evidence(_provider, nil, _requests, _context), do: :skipped

  defp provider_evidence("telegram", _adapter, requests, context) do
    %{
      long_poll_started?: true,
      chat_id: context.telegram_chat_id,
      mapped_user_id: context.telegram_user_id,
      runtime_request?: Map.has_key?(requests, "telegram"),
      runtime_text: requests["telegram"].text
    }
  end

  defp provider_evidence("email", _adapter, requests, context) do
    %{
      imap_poll_started?: true,
      mailbox: context.email_from_address,
      mapped_sender: context.email_mapped_sender,
      runtime_request?: Map.has_key?(requests, "email"),
      runtime_text: requests["email"].text
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

  defp write_evidence!(home, started_at, evidence) do
    evidence_dir = Path.join(home, "release_evidence/v053")
    File.mkdir_p!(evidence_dir)
    provider_slug = Enum.join(["inbound" | evidence.providers], "-")

    body =
      Map.merge(evidence, %{
        gate:
          "mix allbert.test external-smoke -- #{Enum.join(["inbound" | evidence.providers], "_")}",
        version: "v0.53",
        status: "passed",
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        started_at: DateTime.to_iso8601(started_at),
        secret_material:
          "redacted; tokens and passwords stored only through Settings Central secret refs"
      })

    path =
      Path.join(
        evidence_dir,
        "external-smoke-#{provider_slug}-#{DateTime.to_unix(started_at)}.json"
      )

    File.write!(path, Jason.encode!(body, pretty: true))
    path
  end

  defp put_targeted_secrets!(providers) do
    if "telegram" in providers do
      put_secret!(
        "secret://channels/telegram/bot_token",
        System.fetch_env!("ALLBERT_TELEGRAM_BOT_TOKEN")
      )
    end

    if "email" in providers do
      put_secret!(
        "secret://channels/email/imap_password",
        System.fetch_env!("ALLBERT_EMAIL_IMAP_PASSWORD")
      )

      put_secret!(
        "secret://channels/email/smtp_password",
        System.fetch_env!("ALLBERT_EMAIL_SMTP_PASSWORD")
      )
    end
  end

  defp put_secret!(secret_ref, value) do
    assert {:ok, _secret} = Secrets.put_secret(secret_ref, value, %{audit?: false})
  end

  defp put_setting!(key, value) do
    assert {:ok, _setting} = Settings.put(key, value, %{audit?: false})
  end

  defp timeout_ms(["telegram"]) do
    timeout_from_env([
      "ALLBERT_TELEGRAM_INBOUND_TIMEOUT_MS",
      "ALLBERT_TELEGRAM_EMAIL_INBOUND_TIMEOUT_MS",
      "ALLBERT_MESSAGING_CHANNEL_INBOUND_TIMEOUT_MS"
    ])
  end

  defp timeout_ms(["email"]) do
    timeout_from_env([
      "ALLBERT_EMAIL_INBOUND_TIMEOUT_MS",
      "ALLBERT_TELEGRAM_EMAIL_INBOUND_TIMEOUT_MS",
      "ALLBERT_MESSAGING_CHANNEL_INBOUND_TIMEOUT_MS"
    ])
  end

  defp timeout_ms(_providers) do
    timeout_from_env([
      "ALLBERT_TELEGRAM_EMAIL_INBOUND_TIMEOUT_MS",
      "ALLBERT_MESSAGING_CHANNEL_INBOUND_TIMEOUT_MS"
    ])
  end

  defp timeout_from_env(env_names) do
    case Enum.find_value(env_names, &System.get_env/1) do
      nil -> 120_000
      value -> String.to_integer(value)
    end
  end

  defp parse_bool(value) when value in [true, "true", "1", "yes"], do: true
  defp parse_bool(_value), do: false

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
