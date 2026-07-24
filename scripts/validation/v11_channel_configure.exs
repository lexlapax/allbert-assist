alias AllbertAssist.CLI.Areas.Channels
alias AllbertAssist.CLI.Areas.Settings
alias AllbertAssist.Settings.Secrets

Logger.configure(level: :warning)
channel_supervisor = AllbertAssist.Channels.Supervisor
opts = Application.get_env(:allbert_assist, channel_supervisor, [])
Application.put_env(:allbert_assist, channel_supervisor, Keyword.put(opts, :auto_poll?, false))
{:ok, _started} = Application.ensure_all_started(:allbert_assist)

channels =
  System.fetch_env!("V11_CHANNEL")
  |> String.split(",", trim: true)

context = %{actor: "operator", channel: :cli}

required = fn names ->
  Map.new(names, fn name ->
    case System.fetch_env(name) do
      {:ok, ""} -> raise "required environment variable is empty: #{name}"
      {:ok, value} -> {name, value}
      :error -> raise "required environment variable is missing: #{name}"
    end
  end)
end

dispatch = fn area, args, label ->
  {output, code} = area.dispatch(args)
  IO.puts(String.trim_trailing(output))

  if code != 0 do
    raise "#{label} failed"
  end
end

set = fn key, value ->
  {output, code} = Settings.dispatch(["set", key, to_string(value)])
  IO.puts(String.trim_trailing(output))

  if code != 0 do
    raise "failed to persist #{key}"
  end
end

put_secret = fn ref, value ->
  case Secrets.put_secret(ref, value, context) do
    {:ok, _result} -> IO.puts("Configured encrypted secret: #{ref}")
    {:error, reason} -> raise "failed to store #{ref}: #{inspect(reason)}"
  end
end

Enum.each(channels, fn channel ->
  case channel do
    "telegram" ->
      env =
        required.([
          "ALLBERT_TELEGRAM_BOT_TOKEN",
          "ALLBERT_TELEGRAM_CHAT_ID",
          "ALLBERT_TELEGRAM_USER_ID"
        ])

      dispatch.(
        Channels,
        ["telegram", "set-token", env["ALLBERT_TELEGRAM_BOT_TOKEN"]],
        "telegram token"
      )

      set.("channels.telegram.allowed_chat_ids", ~s(["#{env["ALLBERT_TELEGRAM_CHAT_ID"]}"]))
      set.("channels.telegram.allow_group_chats", false)

      dispatch.(
        Channels,
        [
          "telegram",
          "map",
          "--external-user",
          env["ALLBERT_TELEGRAM_USER_ID"],
          "--user",
          "local"
        ],
        "telegram identity"
      )

      set.("channels.telegram.enabled", true)

    "email" ->
      env =
        required.([
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
        ])

      set.("channels.email.imap_host", env["ALLBERT_EMAIL_IMAP_HOST"])
      set.("channels.email.imap_port", env["ALLBERT_EMAIL_IMAP_PORT"])
      set.("channels.email.imap_ssl", true)
      set.("channels.email.imap_username", env["ALLBERT_EMAIL_IMAP_USERNAME"])

      dispatch.(
        Channels,
        ["email", "set-password", "--type", "imap", env["ALLBERT_EMAIL_IMAP_PASSWORD"]],
        "email IMAP password"
      )

      set.("channels.email.imap_mailbox", System.get_env("ALLBERT_EMAIL_IMAP_MAILBOX", "INBOX"))
      set.("channels.email.smtp_host", env["ALLBERT_EMAIL_SMTP_HOST"])
      set.("channels.email.smtp_port", env["ALLBERT_EMAIL_SMTP_PORT"])
      set.("channels.email.smtp_tls", true)
      set.("channels.email.smtp_username", env["ALLBERT_EMAIL_SMTP_USERNAME"])

      dispatch.(
        Channels,
        ["email", "set-password", "--type", "smtp", env["ALLBERT_EMAIL_SMTP_PASSWORD"]],
        "email SMTP password"
      )

      set.("channels.email.from_address", env["ALLBERT_EMAIL_FROM_ADDRESS"])

      dispatch.(
        Channels,
        [
          "email",
          "map",
          "--external-user",
          env["ALLBERT_EMAIL_MAPPED_SENDER"],
          "--user",
          "local"
        ],
        "email identity"
      )

      set.("channels.email.enabled", true)

    "discord" ->
      env =
        required.([
          "ALLBERT_DISCORD_BOT_TOKEN",
          "ALLBERT_DISCORD_APPLICATION_ID",
          "ALLBERT_DISCORD_GUILD_ID",
          "ALLBERT_DISCORD_CHANNEL_ID",
          "ALLBERT_DISCORD_USER_ID"
        ])

      put_secret.("secret://channels/discord/bot_token", env["ALLBERT_DISCORD_BOT_TOKEN"])

      for {args, label} <- [
            {["discord", "set-token", "secret://channels/discord/bot_token"], "discord token"},
            {["discord", "set-application-id", env["ALLBERT_DISCORD_APPLICATION_ID"]],
             "discord application"},
            {["discord", "add-guild", env["ALLBERT_DISCORD_GUILD_ID"]], "discord guild"},
            {["discord", "add-channel", env["ALLBERT_DISCORD_CHANNEL_ID"]], "discord channel"},
            {[
               "discord",
               "map",
               "--external-user",
               env["ALLBERT_DISCORD_USER_ID"],
               "--user",
               "local"
             ], "discord identity"}
          ] do
        dispatch.(Channels, args, label)
      end

      set.("channels.discord.enabled", true)

    "slack" ->
      env =
        required.([
          "ALLBERT_SLACK_BOT_TOKEN",
          "ALLBERT_SLACK_APP_TOKEN",
          "ALLBERT_SLACK_TEAM_ID",
          "ALLBERT_SLACK_CHANNEL_ID",
          "ALLBERT_SLACK_USER_ID"
        ])

      put_secret.("secret://channels/slack/bot_token", env["ALLBERT_SLACK_BOT_TOKEN"])
      put_secret.("secret://channels/slack/app_token", env["ALLBERT_SLACK_APP_TOKEN"])

      for {args, label} <- [
            {["slack", "set-token", "secret://channels/slack/bot_token"], "slack token"},
            {["slack", "set-app-token", "secret://channels/slack/app_token"], "slack app token"},
            {["slack", "set-team-id", env["ALLBERT_SLACK_TEAM_ID"]], "slack team"},
            {["slack", "add-channel", env["ALLBERT_SLACK_CHANNEL_ID"]], "slack channel"},
            {[
               "slack",
               "map",
               "--external-user",
               env["ALLBERT_SLACK_USER_ID"],
               "--user",
               "local"
             ], "slack identity"}
          ] do
        dispatch.(Channels, args, label)
      end

      set.("channels.slack.enabled", true)

    "matrix" ->
      env =
        required.([
          "ALLBERT_MATRIX_HOMESERVER_URL",
          "ALLBERT_MATRIX_ACCESS_TOKEN",
          "ALLBERT_MATRIX_BOT_USER",
          "ALLBERT_MATRIX_ROOM_ID",
          "ALLBERT_MATRIX_USER_ID"
        ])

      set.("channels.matrix.homeserver_url", env["ALLBERT_MATRIX_HOMESERVER_URL"])

      dispatch.(
        Channels,
        ["matrix", "set-token", env["ALLBERT_MATRIX_ACCESS_TOKEN"]],
        "matrix token"
      )

      set.("channels.matrix.user_id", env["ALLBERT_MATRIX_BOT_USER"])
      set.("channels.matrix.allowed_room_ids", ~s(["#{env["ALLBERT_MATRIX_ROOM_ID"]}"]))

      dispatch.(
        Channels,
        ["matrix", "map", "--external-user", env["ALLBERT_MATRIX_USER_ID"], "--user", "local"],
        "matrix identity"
      )

      set.("channels.matrix.enabled", true)

    "whatsapp" ->
      env =
        required.([
          "ALLBERT_WHATSAPP_ACCESS_TOKEN",
          "ALLBERT_WHATSAPP_PHONE_NUMBER_ID",
          "ALLBERT_WHATSAPP_WABA_ID",
          "ALLBERT_WHATSAPP_MAPPED_PHONE",
          "ALLBERT_WHATSAPP_APP_SECRET",
          "ALLBERT_WHATSAPP_WEBHOOK_VERIFY_TOKEN"
        ])

      dispatch.(
        Channels,
        ["whatsapp", "set-token", env["ALLBERT_WHATSAPP_ACCESS_TOKEN"]],
        "whatsapp token"
      )

      set.("channels.whatsapp.phone_number_id", env["ALLBERT_WHATSAPP_PHONE_NUMBER_ID"])
      set.("channels.whatsapp.waba_id", env["ALLBERT_WHATSAPP_WABA_ID"])

      dispatch.(
        Channels,
        [
          "whatsapp",
          "map",
          "--external-user",
          env["ALLBERT_WHATSAPP_MAPPED_PHONE"],
          "--user",
          "local"
        ],
        "whatsapp identity"
      )

      put_secret.("secret://channels/whatsapp/app_secret", env["ALLBERT_WHATSAPP_APP_SECRET"])

      put_secret.(
        "secret://channels/whatsapp/webhook_verify_token",
        env["ALLBERT_WHATSAPP_WEBHOOK_VERIFY_TOKEN"]
      )

      set.("channels.whatsapp.webhook_enabled", true)
      set.("channels.whatsapp.enabled", true)

    "signal" ->
      env =
        required.([
          "ALLBERT_SIGNAL_ACCOUNT",
          "ALLBERT_SIGNAL_LOCAL_ACI",
          "ALLBERT_SIGNAL_MAPPED_ACI"
        ])

      signal_dir = Path.join(System.fetch_env!("ALLBERT_HOME"), "signal")
      File.mkdir_p!(signal_dir)
      File.chmod!(signal_dir, 0o700)
      set.("channels.signal.account_identifier", env["ALLBERT_SIGNAL_ACCOUNT"])
      set.("channels.signal.local_aci", env["ALLBERT_SIGNAL_LOCAL_ACI"])
      set.("channels.signal.data_dir", signal_dir)

      dispatch.(
        Channels,
        ["signal", "map", "--aci", env["ALLBERT_SIGNAL_MAPPED_ACI"], "--user", "local"],
        "signal identity"
      )

      case System.get_env("ALLBERT_SIGNAL_CONTROL_HTTP_BASE_URL") do
        nil ->
          set.("channels.signal.control_mode", "socket")
          set.("channels.signal.socket_path", Path.join(signal_dir, "signal-cli.sock"))

        "" ->
          set.("channels.signal.control_mode", "socket")
          set.("channels.signal.socket_path", Path.join(signal_dir, "signal-cli.sock"))

        base_url ->
          auth = required.(["ALLBERT_SIGNAL_CONTROL_AUTH"])

          put_secret.(
            "secret://channels/signal/control_auth",
            auth["ALLBERT_SIGNAL_CONTROL_AUTH"]
          )

          set.("channels.signal.control_mode", "loopback_http")
          set.("channels.signal.loopback_http_base_url", base_url)
      end

      set.("channels.signal.enabled", true)

    other ->
      raise "unsupported channel: #{other}"
  end

  {show_output, show_code} = Channels.dispatch(["show", channel])
  IO.puts(String.trim_trailing(show_output))

  if show_code != 0 or not String.contains?(show_output, "Enabled: true") or
       not String.contains?(show_output, "Identities: 1") do
    raise "#{channel} post-configuration verification failed"
  end

  IO.puts("V11 CHANNEL CONFIGURATION PASS channel=#{channel}")
end)
