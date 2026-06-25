defmodule Mix.Tasks.Allbert.Channels do
  @moduledoc """
  Inspect and operate local channel adapters.

  ## Usage

      mix allbert.channels list
      mix allbert.channels status
      mix allbert.channels show telegram|email|discord|slack|matrix|whatsapp|signal
      mix allbert.channels setup-check matrix|whatsapp|signal
      mix allbert.channels telegram set-token TOKEN
      mix allbert.channels telegram map --external-user EXTERNAL --user USER
      mix allbert.channels telegram unmap --external-user EXTERNAL
      mix allbert.channels telegram simulate --external-user EXTERNAL --chat CHAT "prompt"
      mix allbert.channels telegram poll-once
      mix allbert.channels telegram doctor
      mix allbert.channels email set-password --type imap PASSWORD
      mix allbert.channels email set-password --type smtp PASSWORD
      mix allbert.channels email map --external-user EMAIL --user USER
      mix allbert.channels email unmap --external-user EMAIL
      mix allbert.channels email simulate --external-user EMAIL [--new-thread] "prompt"
      mix allbert.channels email poll-once
      mix allbert.channels email doctor
      mix allbert.channels identity-links add --link LINK --channel CHANNEL --receiver RECEIVER --external-user EXTERNAL --user USER
      mix allbert.channels identity-links list [--link LINK] [--user USER]
      mix allbert.channels identity-links remove --link LINK --channel CHANNEL --receiver RECEIVER --external-user EXTERNAL
      mix allbert.channels discord set-token TOKEN_REF
      mix allbert.channels discord set-application-id APPLICATION_ID
      mix allbert.channels discord add-guild GUILD_ID
      mix allbert.channels discord add-channel CHANNEL_ID
      mix allbert.channels discord map --external-user EXTERNAL --user USER
      mix allbert.channels discord simulate --guild GUILD --channel CHANNEL --user EXTERNAL "prompt"
      mix allbert.channels discord simulate-callback --user EXTERNAL --custom-id allbert:v1:<verb>:<id>
      mix allbert.channels discord doctor
      mix allbert.channels slack set-token TOKEN_REF
      mix allbert.channels slack set-app-token APP_TOKEN_REF
      mix allbert.channels slack set-team-id TEAM_ID
      mix allbert.channels slack add-channel CHANNEL_ID
      mix allbert.channels slack map --external-user EXTERNAL --user USER
      mix allbert.channels slack simulate --channel CHANNEL [--thread-ts TS] --user EXTERNAL "prompt"
      mix allbert.channels slack simulate-callback --channel CHANNEL --user EXTERNAL --action-id allbert:v1:<verb>:<id>
      mix allbert.channels slack doctor
      mix allbert.channels matrix set-token TOKEN
      mix allbert.channels matrix map --external-user MXID --user USER
      mix allbert.channels matrix unmap --external-user MXID
      mix allbert.channels matrix simulate --room ROOM --user MXID "prompt"
      mix allbert.channels matrix poll-once
      mix allbert.channels matrix doctor
      mix allbert.channels whatsapp set-token TOKEN
      mix allbert.channels whatsapp map --external-user PHONE --user USER
      mix allbert.channels whatsapp unmap --external-user PHONE
      mix allbert.channels whatsapp simulate --from PHONE [--message-id WAMID] "prompt"
      mix allbert.channels whatsapp simulate-button --from PHONE --button-id allbert:v1:<verb>:<id>
      mix allbert.channels whatsapp post-webhook --from PHONE [--message-id WAMID] [--bad-signature] [--url BASE] "prompt"
      mix allbert.channels whatsapp doctor
      mix allbert.channels signal map --aci ACI --user USER
      mix allbert.channels signal unmap --aci ACI
      mix allbert.channels signal simulate --aci ACI [--message-id TIMESTAMP_MS] "prompt"
      mix allbert.channels signal link --account ACCOUNT [--device-name NAME]
      mix allbert.channels signal doctor
  """

  use Mix.Task

  import Ecto.Query

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.ChannelParity
  alias AllbertAssist.Channels.Discord
  alias AllbertAssist.Channels.Email
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.Matrix
  alias AllbertAssist.Channels.Signal
  alias AllbertAssist.Channels.Slack
  alias AllbertAssist.Channels.Telegram
  alias AllbertAssist.Channels.WhatsApp
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Surfaces.ContextBuilder

  @shortdoc "Inspect and operate local channel adapters"
  @simulate_gateway_timeout_ms 120_000

  @switches [
    action_id: :string,
    account: :string,
    aci: :string,
    bad_signature: :boolean,
    button_id: :string,
    chat: :string,
    channel: :string,
    custom_id: :string,
    device_name: :string,
    external_user: :string,
    guild: :string,
    link: :string,
    from: :string,
    message_id: :string,
    new_thread: :boolean,
    receiver: :string,
    room: :string,
    thread_ts: :string,
    thread_channel: :string,
    type: :string,
    url: :string,
    user: :string
  ]

  @impl true
  def run(args) do
    disable_channel_auto_poll!()
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp disable_channel_auto_poll! do
    opts = Application.get_env(:allbert_assist, AllbertAssist.Channels.Supervisor, [])

    Application.put_env(
      :allbert_assist,
      AllbertAssist.Channels.Supervisor,
      Keyword.put(opts, :auto_poll?, false)
    )
  end

  defp dispatch(["list"]) do
    with {:ok, response} <-
           completed_action("list_channels", operator_report_params()) do
      {:ok, {:list, response.channels}}
    end
  end

  defp dispatch(["status"]) do
    with {:ok, response} <- completed_action("operator_channels", %{}) do
      {:ok, {:status, response}}
    end
  end

  defp dispatch(["--parity"]), do: dispatch(["parity"])

  defp dispatch(["parity"]) do
    case ChannelParity.verify() do
      :ok -> {:ok, {:parity, ChannelParity.table()}}
      {:error, errors} -> {:error, {:channel_parity_drift, errors}}
    end
  end

  defp dispatch(["show", channel]) do
    with {:ok, response} <- completed_action("show_channel", %{channel: channel}) do
      {:ok, {:show, response.channel}}
    end
  end

  defp dispatch(["setup-check", channel]) do
    with {:ok, response} <- completed_action("channel_setup_check", %{channel: channel}) do
      {:ok, {:setup_check, response.setup}}
    end
  end

  defp dispatch(["telegram", "set-token", token]) do
    with {:ok, _secret} <-
           Secrets.put_secret("secret://channels/telegram/bot_token", token, secret_context()),
         {:ok, _setting} <-
           Settings.put(
             "channels.telegram.bot_token_ref",
             "secret://channels/telegram/bot_token",
             %{audit?: false}
           ) do
      {:ok, {:secret, "telegram", "bot_token"}}
    end
  end

  defp dispatch(["telegram", "map" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!("telegram", required!(opts, :external_user), required!(opts, :user))
  end

  defp dispatch(["telegram", "unmap" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!("telegram", required!(opts, :external_user))
  end

  defp dispatch(["telegram", "simulate" | rest]) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_telegram!(
      required!(opts, :external_user),
      required!(opts, :chat),
      single_arg!(args, "Prompt is required")
    )
  end

  defp dispatch(["telegram", "poll-once"]) do
    {:ok, {:poll, "telegram", Telegram.Adapter.poll_once()}}
  end

  defp dispatch(["telegram", "doctor"]) do
    with {:ok, response} <- completed_action("telegram_doctor", %{}) do
      {:ok, {:doctor, "telegram", response.doctor}}
    end
  end

  defp dispatch(["email", "set-password" | rest]) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)
    type = required!(opts, :type)
    password = single_arg!(args, "Password is required")
    set_email_password!(type, password)
  end

  defp dispatch(["email", "map" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!("email", required!(opts, :external_user), required!(opts, :user))
  end

  defp dispatch(["email", "unmap" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!("email", required!(opts, :external_user))
  end

  defp dispatch(["email", "simulate" | rest]) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_email!(
      required!(opts, :external_user),
      single_arg!(args, "Prompt is required"),
      Keyword.get(opts, :new_thread, false)
    )
  end

  defp dispatch(["email", "poll-once"]) do
    {:ok, {:poll, "email", Email.Adapter.poll_once()}}
  end

  defp dispatch(["email", "doctor"]) do
    with {:ok, response} <- completed_action("email_doctor", %{}) do
      {:ok, {:doctor, "email", response.doctor}}
    end
  end

  defp dispatch(["matrix", "set-token", token]) do
    with {:ok, _secret} <-
           Secrets.put_secret("secret://channels/matrix/access_token", token, secret_context()),
         {:ok, _setting} <-
           Settings.put(
             "channels.matrix.access_token_ref",
             "secret://channels/matrix/access_token",
             %{audit?: false}
           ) do
      {:ok, {:secret, "matrix", "access_token"}}
    end
  end

  defp dispatch(["matrix", "map" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!("matrix", required!(opts, :external_user), required!(opts, :user))
  end

  defp dispatch(["matrix", "unmap" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!("matrix", required!(opts, :external_user))
  end

  defp dispatch(["matrix", "simulate" | rest]) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_matrix!(
      required!(opts, :user),
      required!(opts, :room),
      single_arg!(args, "Prompt is required")
    )
  end

  defp dispatch(["matrix", "poll-once"]) do
    {:ok, {:poll, "matrix", Matrix.Adapter.poll_once()}}
  end

  defp dispatch(["matrix", "doctor"]) do
    with {:ok, response} <- completed_action("matrix_doctor", %{}) do
      {:ok, {:doctor, "matrix", response.doctor}}
    end
  end

  defp dispatch(["whatsapp", "set-token", token]) do
    with {:ok, _secret} <-
           Secrets.put_secret("secret://channels/whatsapp/access_token", token, secret_context()),
         {:ok, _setting} <-
           Settings.put(
             "channels.whatsapp.access_token_ref",
             "secret://channels/whatsapp/access_token",
             %{audit?: false}
           ) do
      {:ok, {:secret, "whatsapp", "access_token"}}
    end
  end

  defp dispatch(["whatsapp", "map" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!("whatsapp", required!(opts, :external_user), required!(opts, :user))
  end

  defp dispatch(["whatsapp", "unmap" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!("whatsapp", required!(opts, :external_user))
  end

  defp dispatch(["whatsapp", "simulate" | rest]) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_whatsapp!(
      required!(opts, :from),
      Keyword.get(opts, :message_id),
      single_arg!(args, "Prompt is required")
    )
  end

  defp dispatch(["whatsapp", "simulate-button" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_whatsapp_button!(
      required!(opts, :from),
      required!(opts, :button_id)
    )
  end

  defp dispatch(["whatsapp", "post-webhook" | rest]) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    post_whatsapp_webhook!(
      required!(opts, :from),
      Keyword.get(opts, :message_id),
      Keyword.get(opts, :bad_signature, false),
      Keyword.get(opts, :url),
      single_arg!(args, "Prompt is required")
    )
  end

  defp dispatch(["whatsapp", "doctor"]) do
    with {:ok, response} <- completed_action("whatsapp_doctor", %{}) do
      {:ok, {:doctor, "whatsapp", response.doctor}}
    end
  end

  defp dispatch(["signal", "map" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_signal_identity!(required!(opts, :aci), required!(opts, :user))
  end

  defp dispatch(["signal", "unmap" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!("signal", normalize_signal_aci!(required!(opts, :aci)))
  end

  defp dispatch(["signal", "simulate" | rest]) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_signal!(
      required!(opts, :aci),
      Keyword.get(opts, :message_id),
      single_arg!(args, "Prompt is required")
    )
  end

  defp dispatch(["signal", "link" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    with {:ok, response} <-
           completed_action("signal_link_device", %{
             account: required!(opts, :account),
             device_name: Keyword.get(opts, :device_name, "Allbert")
           }) do
      {:ok, {:signal_link, response}}
    end
  end

  defp dispatch(["signal", "doctor"]) do
    with {:ok, response} <- completed_action("signal_doctor", %{}) do
      {:ok, {:doctor, "signal", response.doctor}}
    end
  end

  defp dispatch(["identity-links", "add" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    attrs = %{
      link_id: required!(opts, :link),
      user_id: required!(opts, :user),
      channel: required!(opts, :channel),
      receiver_account_ref: required!(opts, :receiver),
      external_user_id: required!(opts, :external_user)
    }

    with {:ok, link} <- ChannelThread.link_identity(attrs) do
      {:ok, {:identity_link, link}}
    end
  end

  defp dispatch(["identity-links", "list" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    filters =
      %{
        link_id: Keyword.get(opts, :link),
        user_id: Keyword.get(opts, :user),
        channel: Keyword.get(opts, :channel),
        receiver_account_ref: Keyword.get(opts, :receiver)
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    {:ok, {:identity_links, ChannelThread.list_identity_links(filters)}}
  end

  defp dispatch(["identity-links", "remove" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    attrs = %{
      link_id: required!(opts, :link),
      channel: required!(opts, :channel),
      receiver_account_ref: required!(opts, :receiver),
      external_user_id: required!(opts, :external_user)
    }

    with {:ok, link} <- ChannelThread.unlink_identity(attrs) do
      {:ok, {:identity_unlinked, link}}
    end
  end

  defp dispatch(["discord", "set-token", token_ref]) do
    with :ok <- validate_discord_token_ref(token_ref),
         {:ok, _setting} <-
           Settings.put("channels.discord.bot_token_ref", token_ref, %{audit?: false}) do
      {:ok, {:secret_ref, "discord", "bot_token"}}
    end
  end

  defp dispatch(["discord", "set-application-id", application_id]) do
    with {:ok, _setting} <-
           Settings.put("channels.discord.application_id", application_id, %{audit?: false}) do
      {:ok, {:setting, "discord", "application_id", application_id}}
    end
  end

  defp dispatch(["discord", "add-guild", guild_id]) do
    add_setting_list_value!("discord", "allowed_guild_ids", guild_id)
  end

  defp dispatch(["discord", "remove-guild", guild_id]) do
    remove_setting_list_value!("discord", "allowed_guild_ids", guild_id)
  end

  defp dispatch(["discord", "add-channel", channel_id]) do
    add_setting_list_value!("discord", "allowed_channel_ids", channel_id)
  end

  defp dispatch(["discord", "remove-channel", channel_id]) do
    remove_setting_list_value!("discord", "allowed_channel_ids", channel_id)
  end

  defp dispatch(["discord", "map" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!("discord", required!(opts, :external_user), required!(opts, :user))
  end

  defp dispatch(["discord", "unmap" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!("discord", required!(opts, :external_user))
  end

  defp dispatch(["discord", "simulate" | rest]) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_discord!(
      required!(opts, :guild),
      required!(opts, :channel),
      required!(opts, :user),
      Keyword.get(opts, :thread_channel),
      single_arg!(args, "Prompt is required")
    )
  end

  defp dispatch(["discord", "simulate-callback" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_discord_callback!(
      required!(opts, :user),
      required!(opts, :custom_id)
    )
  end

  defp dispatch(["discord", "doctor"]) do
    with {:ok, response} <- completed_action("discord_doctor", %{}) do
      {:ok, {:doctor, "discord", response.doctor}}
    end
  end

  defp dispatch(["slack", "set-token", token_ref]) do
    with :ok <- validate_slack_token_ref(token_ref, :bot),
         {:ok, _setting} <-
           Settings.put("channels.slack.bot_token_ref", token_ref, %{audit?: false}) do
      {:ok, {:secret_ref, "slack", "bot_token"}}
    end
  end

  defp dispatch(["slack", "set-app-token", token_ref]) do
    with :ok <- validate_slack_token_ref(token_ref, :app),
         {:ok, _setting} <-
           Settings.put("channels.slack.app_token_ref", token_ref, %{audit?: false}) do
      {:ok, {:secret_ref, "slack", "app_token"}}
    end
  end

  defp dispatch(["slack", "set-team-id", team_id]) do
    with {:ok, _setting} <-
           Settings.put("channels.slack.workspace_team_id", team_id, %{audit?: false}) do
      {:ok, {:setting, "slack", "workspace_team_id", team_id}}
    end
  end

  defp dispatch(["slack", "add-channel", channel_id]) do
    add_setting_list_value!("slack", "allowed_channel_ids", channel_id)
  end

  defp dispatch(["slack", "remove-channel", channel_id]) do
    remove_setting_list_value!("slack", "allowed_channel_ids", channel_id)
  end

  defp dispatch(["slack", "map" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!("slack", required!(opts, :external_user), required!(opts, :user))
  end

  defp dispatch(["slack", "unmap" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!("slack", required!(opts, :external_user))
  end

  defp dispatch(["slack", "simulate" | rest]) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_slack!(
      required!(opts, :channel),
      required!(opts, :user),
      Keyword.get(opts, :thread_ts),
      single_arg!(args, "Prompt is required")
    )
  end

  defp dispatch(["slack", "simulate-callback" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_slack_callback!(
      required!(opts, :user),
      required!(opts, :channel),
      required!(opts, :action_id)
    )
  end

  defp dispatch(["slack", "doctor"]) do
    with {:ok, response} <- completed_action("slack_doctor", %{}) do
      {:ok, {:doctor, "slack", response.doctor}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.channels list
      mix allbert.channels status
      mix allbert.channels --parity
      mix allbert.channels show telegram|email|discord|slack|matrix|whatsapp|signal
      mix allbert.channels setup-check matrix|whatsapp|signal
      mix allbert.channels telegram set-token TOKEN
      mix allbert.channels telegram map --external-user EXTERNAL --user USER
      mix allbert.channels telegram unmap --external-user EXTERNAL
      mix allbert.channels telegram simulate --external-user EXTERNAL --chat CHAT "prompt"
      mix allbert.channels telegram poll-once
      mix allbert.channels telegram doctor
      mix allbert.channels email set-password --type imap|smtp PASSWORD
      mix allbert.channels email map --external-user EMAIL --user USER
      mix allbert.channels email unmap --external-user EMAIL
      mix allbert.channels email simulate --external-user EMAIL [--new-thread] "prompt"
      mix allbert.channels email poll-once
      mix allbert.channels email doctor
      mix allbert.channels identity-links add --link LINK --channel CHANNEL --receiver RECEIVER --external-user EXTERNAL --user USER
      mix allbert.channels identity-links list [--link LINK] [--user USER]
      mix allbert.channels identity-links remove --link LINK --channel CHANNEL --receiver RECEIVER --external-user EXTERNAL
      mix allbert.channels discord set-token TOKEN_REF
      mix allbert.channels discord set-application-id APPLICATION_ID
      mix allbert.channels discord add-guild GUILD_ID
      mix allbert.channels discord remove-guild GUILD_ID
      mix allbert.channels discord add-channel CHANNEL_ID
      mix allbert.channels discord remove-channel CHANNEL_ID
      mix allbert.channels discord map --external-user EXTERNAL --user USER
      mix allbert.channels discord unmap --external-user EXTERNAL
      mix allbert.channels discord simulate --guild GUILD --channel CHANNEL --user EXTERNAL "prompt"
      mix allbert.channels discord simulate --guild GUILD --channel CHANNEL --thread-channel THREAD --user EXTERNAL "prompt"
      mix allbert.channels discord simulate-callback --user EXTERNAL --custom-id allbert:v1:<verb>:<id>
      mix allbert.channels discord doctor
      mix allbert.channels slack set-token TOKEN_REF
      mix allbert.channels slack set-app-token APP_TOKEN_REF
      mix allbert.channels slack set-team-id TEAM_ID
      mix allbert.channels slack add-channel CHANNEL_ID
      mix allbert.channels slack remove-channel CHANNEL_ID
      mix allbert.channels slack map --external-user EXTERNAL --user USER
      mix allbert.channels slack unmap --external-user EXTERNAL
      mix allbert.channels slack simulate --channel CHANNEL --user EXTERNAL "prompt"
      mix allbert.channels slack simulate --channel CHANNEL --thread-ts TS --user EXTERNAL "prompt"
      mix allbert.channels slack simulate-callback --channel CHANNEL --user EXTERNAL --action-id allbert:v1:<verb>:<id>
      mix allbert.channels slack doctor
      mix allbert.channels matrix set-token TOKEN
      mix allbert.channels matrix map --external-user MXID --user USER
      mix allbert.channels matrix unmap --external-user MXID
      mix allbert.channels matrix simulate --room ROOM --user MXID "prompt"
      mix allbert.channels matrix poll-once
      mix allbert.channels matrix doctor
      mix allbert.channels whatsapp set-token TOKEN
      mix allbert.channels whatsapp map --external-user PHONE --user USER
      mix allbert.channels whatsapp unmap --external-user PHONE
      mix allbert.channels whatsapp simulate --from PHONE [--message-id WAMID] "prompt"
      mix allbert.channels whatsapp simulate-button --from PHONE --button-id allbert:v1:<verb>:<id>
      mix allbert.channels whatsapp post-webhook --from PHONE [--message-id WAMID] [--bad-signature] [--url BASE] "prompt"
      mix allbert.channels whatsapp doctor
      mix allbert.channels signal map --aci ACI --user USER
      mix allbert.channels signal unmap --aci ACI
      mix allbert.channels signal simulate --aci ACI [--message-id TIMESTAMP_MS] "prompt"
      mix allbert.channels signal link --account ACCOUNT [--device-name NAME]
      mix allbert.channels signal doctor
    """)
  end

  defp print_result({:ok, {:list, channels}}) do
    Enum.each(channels, fn channel ->
      Mix.shell().info(
        "#{channel.channel} provider=#{channel.provider} release=#{channel.release_status} enabled=#{channel.enabled} identities=#{channel.identity_count} credentials=#{credential_status(channel.credential_status)}"
      )
    end)
  end

  defp print_result({:ok, {:status, response}}) do
    response
    |> response_value(:surface_payload)
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end

  defp print_result({:ok, {:parity, table}}) do
    Mix.shell().info(table)
  end

  defp print_result({:ok, {:show, channel}}) do
    Mix.shell().info("Channel: #{channel.channel}")
    Mix.shell().info("Provider: #{channel.provider}")
    Mix.shell().info("Release status: #{channel.release_status}")
    maybe_print_release_decision(channel)
    Mix.shell().info("Enabled: #{channel.enabled}")
    Mix.shell().info("Identities: #{channel.identity_count}")
    Mix.shell().info("Credentials: #{credential_status(channel.credential_status)}")
    maybe_print_doctor(channel)
    Mix.shell().info("Last event: #{inspect(channel.last_event)}")
  end

  defp print_result({:ok, {:setup_check, setup}}) do
    Mix.shell().info("#{setup.channel} setup status=#{setup.setup_status}")
    Mix.shell().info("release=#{setup.release_status}")
    maybe_print_release_decision(setup)
    Mix.shell().info("enabled=#{setup.enabled}")
    Mix.shell().info("missing=#{diagnostic_status(setup.diagnostics)}")
    Mix.shell().info("settings=#{setup_fields(setup.required_settings)}")
    Mix.shell().info("secrets=#{secret_fields(setup.secret_status)}")
    Mix.shell().info("doctor=#{Map.get(setup.commands, :doctor)}")
    Mix.shell().info("smoke=#{Map.get(setup.commands, :smoke)}")

    case Map.get(setup.commands, :pair) do
      command when is_binary(command) -> Mix.shell().info("pair=#{command}")
      _command -> :ok
    end

    retry = setup.retry_posture || %{}

    Mix.shell().info(
      "automatic_provider_retry=#{Map.get(retry, :automatic_provider_retry?, false)}"
    )
  end

  defp print_result({:ok, {:secret, channel, secret_name}}) do
    Mix.shell().info("#{channel} #{secret_name}=stored")
  end

  defp print_result({:ok, {:secret_ref, channel, secret_name}}) do
    Mix.shell().info("#{channel} #{secret_name}_ref=stored")
  end

  defp print_result({:ok, {:setting, channel, key, _value}}) do
    Mix.shell().info("#{channel} #{key}=stored")
  end

  defp print_result({:ok, {:list_setting, channel, key, values}}) do
    Mix.shell().info("#{channel} #{key}=#{Enum.join(values, ",")}")
  end

  defp print_result({:ok, {:identity, channel, external_user_id, user_id}}) do
    Mix.shell().info("#{channel} #{external_user_id} -> #{user_id}")
  end

  defp print_result({:ok, {:unmapped, channel, external_user_id}}) do
    Mix.shell().info("#{channel} #{external_user_id} unmapped")
  end

  defp print_result({:ok, {:identity_link, link}}) do
    Mix.shell().info(identity_link_line(link, "linked"))
  end

  defp print_result({:ok, {:identity_unlinked, link}}) do
    Mix.shell().info(identity_link_line(link, "unlinked"))
  end

  defp print_result({:ok, {:identity_links, []}}) do
    Mix.shell().info("identity links: none")
  end

  defp print_result({:ok, {:identity_links, links}}) do
    Enum.each(links, &Mix.shell().info(identity_link_line(&1, "link")))
  end

  defp print_result({:ok, {:simulate, event, rendered}}) do
    Mix.shell().info("Event: #{event.channel}/#{event.external_event_id} status=#{event.status}")
    Mix.shell().info("User: #{event.user_id}")
    Mix.shell().info("Thread: #{event.thread_id}")
    Mix.shell().info("Response:")
    Enum.each(List.wrap(rendered), &Mix.shell().info(&1))
  end

  defp print_result({:ok, {:poll, channel, result}}) do
    Mix.shell().info("#{channel} poll_once: #{inspect(result)}")
  end

  defp print_result({:ok, {:doctor, channel, result}}) do
    Mix.shell().info("#{channel} doctor status=#{Map.get(result, :status)}")

    Mix.shell().info(
      "auth_ok=#{Map.get(result, :auth_ok)} endpoint_ok=#{Map.get(result, :endpoint_ok)}"
    )

    maybe_print_doctor_field("gateway", Map.get(result, :gateway_status))
    maybe_print_doctor_field("socket_mode", Map.get(result, :socket_mode_status))
    maybe_print_doctor_field("poller", Map.get(result, :poller_status))
    maybe_print_doctor_field("adapter", Map.get(result, :adapter_status))
    maybe_print_doctor_field("control", Map.get(result, :control_mode))
    maybe_print_doctor_field("local_only", Map.get(result, :control_local_only))
    maybe_print_doctor_field("imap", Map.get(result, :imap_endpoint_ok))
    maybe_print_doctor_field("smtp", Map.get(result, :smtp_endpoint_ok))
    maybe_print_doctor_field("bot", Map.get(result, :bot_username))
    maybe_print_doctor_field("user", Map.get(result, :user_id))
    maybe_print_doctor_field("rooms", Map.get(result, :allowed_room_count))
  end

  defp print_result({:ok, {:webhook_post, status, body, expected, bad_signature?}}) do
    label =
      if bad_signature?,
        do: "whatsapp post-webhook (bad-signature)",
        else: "whatsapp post-webhook (signed)"

    Mix.shell().info("#{label} -> HTTP #{status}")
    Mix.shell().info("response: #{body}")

    verdict =
      case {expected, status} do
        {:accept_202, 202} ->
          "PASS: signature verified and webhook accepted (HTTP 202)"

        {:deny_401, 401} ->
          "PASS: invalid signature rejected before parse (HTTP 401)"

        {:accept_202, other} ->
          "UNEXPECTED: expected HTTP 202, got #{other} " <>
            "(check that mix phx.server is running and channels.whatsapp.webhook_enabled, " <>
            "phone_number_id, and app_secret_ref are configured)"

        {:deny_401, other} ->
          "UNEXPECTED: expected HTTP 401 for a bad signature, got #{other}"
      end

    Mix.shell().info(verdict)
  end

  defp print_result({:ok, {:signal_link, response}}) do
    Mix.shell().info("signal device_link=status=#{response.status}")
    Mix.shell().info("signal link_data=#{Map.get(response, :link_data)}")
  end

  defp print_result({:error, reason}) do
    Mix.raise("Channels command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params) do
    ActionHelper.completed_action(action_name, params, context())
  end

  defp operator_report_params do
    %{render_mode: "operator_report", surface_policy_affordance: true}
  end

  defp put_identity!(channel, external_user_id, user_id) do
    key = "channels.#{channel}.identity_map"
    {:ok, identity_map} = Settings.get(key)

    entry = %{
      external_user_id: external_user_id,
      user_id: user_id,
      enabled: true
    }

    updated =
      identity_map
      |> Enum.reject(&(identity_field(&1, "external_user_id") == external_user_id))
      |> Kernel.++([entry])

    with {:ok, _setting} <- Settings.put(key, updated, %{audit?: false}) do
      {:ok, {:identity, channel, external_user_id, user_id}}
    end
  end

  defp put_signal_identity!(aci, user_id) do
    aci = normalize_signal_aci!(aci)
    put_identity!("signal", aci, user_id)
  end

  defp remove_identity!(channel, external_user_id) do
    key = "channels.#{channel}.identity_map"
    {:ok, identity_map} = Settings.get(key)

    updated =
      Enum.reject(identity_map, &(identity_field(&1, "external_user_id") == external_user_id))

    with {:ok, _setting} <- Settings.put(key, updated, %{audit?: false}) do
      {:ok, {:unmapped, channel, external_user_id}}
    end
  end

  defp set_email_password!("imap", password) do
    with {:ok, _secret} <-
           Secrets.put_secret("secret://channels/email/imap_password", password, secret_context()),
         {:ok, _setting} <-
           Settings.put(
             "channels.email.imap_password_ref",
             "secret://channels/email/imap_password",
             %{audit?: false}
           ) do
      {:ok, {:secret, "email", "imap_password"}}
    end
  end

  defp set_email_password!("smtp", password) do
    with {:ok, _secret} <-
           Secrets.put_secret("secret://channels/email/smtp_password", password, secret_context()),
         {:ok, _setting} <-
           Settings.put(
             "channels.email.smtp_password_ref",
             "secret://channels/email/smtp_password",
             %{audit?: false}
           ) do
      {:ok, {:secret, "email", "smtp_password"}}
    end
  end

  defp set_email_password!(type, _password), do: {:error, {:unknown_email_password_type, type}}

  defp add_setting_list_value!(channel, key, value) do
    setting_key = "channels.#{channel}.#{key}"
    {:ok, values} = Settings.get(setting_key)
    updated = values |> Kernel.++([to_string(value)]) |> Enum.uniq()

    with {:ok, _setting} <- Settings.put(setting_key, updated, %{audit?: false}) do
      {:ok, {:list_setting, channel, key, updated}}
    end
  end

  defp remove_setting_list_value!(channel, key, value) do
    setting_key = "channels.#{channel}.#{key}"
    {:ok, values} = Settings.get(setting_key)
    updated = Enum.reject(values, &(&1 == to_string(value)))

    with {:ok, _setting} <- Settings.put(setting_key, updated, %{audit?: false}) do
      {:ok, {:list_setting, channel, key, updated}}
    end
  end

  defp simulate_telegram!(external_user_id, chat_id, text) do
    with {:ok, settings} <- Channels.channel_settings("telegram"),
         {:ok, user_id} <-
           Identity.resolve("telegram", external_user_id, Map.get(settings, "identity_map", [])),
         session_id <- Channels.derive_session_id("telegram", external_user_id, chat_id),
         {prompt, new_thread?} <- prompt_text(text),
         {:ok, event} <-
           Channels.create_event(%{
             channel: "telegram",
             provider: "telegram_bot_api",
             direction: "inbound",
             external_event_id: "sim_#{Ecto.UUID.generate()}",
             external_user_id: external_user_id,
             external_chat_id: chat_id,
             status: "received",
             payload_summary: "telegram simulate"
           }),
         {:ok, response} <-
           Runtime.submit_user_input(%{
             text: prompt,
             channel: "telegram",
             user_id: user_id,
             operator_id: user_id,
             session_id: session_id,
             new_thread: new_thread?,
             metadata: simulate_metadata("telegram", "telegram_bot_api", event, nil)
           }),
         {:ok, rendered, _keyboard} <- Telegram.Renderer.render_response(response),
         {:ok, event} <- mark_simulated_event(event, response, user_id, session_id) do
      {:ok, {:simulate, event, rendered}}
    end
  end

  defp simulate_email!(external_user_id, text, forced_new_thread?) do
    with {:ok, settings} <- Channels.channel_settings("email"),
         {:ok, user_id} <-
           Identity.resolve("email", external_user_id, Map.get(settings, "identity_map", [])),
         session_id <- Channels.derive_session_id("email", external_user_id, nil),
         {prompt, prompted_new_thread?} <- prompt_text(text),
         {:ok, event} <-
           Channels.create_event(%{
             channel: "email",
             provider: "email_imap",
             direction: "inbound",
             external_event_id: "sim_#{Ecto.UUID.generate()}",
             external_user_id: external_user_id,
             status: "received",
             payload_summary: "email simulate"
           }),
         {:ok, response} <-
           Runtime.submit_user_input(%{
             text: prompt,
             channel: "email",
             user_id: user_id,
             operator_id: user_id,
             session_id: session_id,
             new_thread: forced_new_thread? or prompted_new_thread?,
             metadata: simulate_metadata("email", "email_imap", event, nil)
           }),
         {:ok, _subject, body, _html} <- Email.Renderer.render_response(response),
         {:ok, event} <- mark_simulated_event(event, response, user_id, session_id) do
      {:ok, {:simulate, event, [body]}}
    end
  end

  defp simulate_matrix!(external_user_id, room_id, text) do
    with {:ok, settings} <- Channels.channel_settings("matrix"),
         {:ok, user_id} <-
           Identity.resolve("matrix", external_user_id, Map.get(settings, "identity_map", [])),
         session_id <- Channels.derive_session_id("matrix", external_user_id, room_id),
         {prompt, new_thread?} <- prompt_text(text),
         {:ok, event} <-
           Channels.create_event(%{
             channel: "matrix",
             provider: "matrix_client_server",
             direction: "inbound",
             external_event_id: "sim_" <> Ecto.UUID.generate(),
             external_user_id: external_user_id,
             external_chat_id: room_id,
             status: "received",
             payload_summary: "matrix simulate"
           }),
         {:ok, response} <-
           Runtime.submit_user_input(%{
             text: prompt,
             channel: "matrix",
             user_id: user_id,
             operator_id: user_id,
             session_id: session_id,
             new_thread: new_thread?,
             metadata: simulate_metadata("matrix", "matrix_client_server", event, nil)
           }),
         {:ok, rendered} <- Matrix.Renderer.render_response(response),
         {:ok, event} <- mark_simulated_event(event, response, user_id, session_id) do
      {:ok, {:simulate, event, rendered}}
    end
  end

  defp simulate_whatsapp!(external_user_id, message_id, text) do
    with {:ok, settings} <- Channels.channel_settings("whatsapp"),
         payload <-
           WhatsApp.Parser.simulated_text_webhook(%{
             from: external_user_id,
             phone_number_id: Map.get(settings, "phone_number_id"),
             display_phone_number: Map.get(settings, "phone_number_id"),
             waba_id: Map.get(settings, "waba_id"),
             message_id: message_id || "sim_" <> Ecto.UUID.generate(),
             text: text
           }),
         {:ok, adapter} <-
           WhatsApp.Adapter.start_link(name: nil, req_options: [mode: :stub]),
         result <- WhatsApp.Adapter.simulate_webhook_event(adapter, payload) do
      GenServer.stop(adapter)
      normalize_whatsapp_simulation(result)
    end
  end

  # Validates the live ADR 0056 signed-webhook auth path locally: it computes the
  # same `sha256=`-prefixed HMAC the ingress checks and issues a real HTTP POST to a
  # running endpoint, so (unlike `whatsapp simulate`, which injects in-process and
  # bypasses the HTTP/signature layer) it exercises `X-Hub-Signature-256`
  # verification before parse. `--bad-signature` sends a wrong digest to confirm the
  # HTTP 401 denial.
  defp post_whatsapp_webhook!(from, message_id, bad_signature?, base_url, text) do
    with {:ok, settings} <- Channels.channel_settings("whatsapp"),
         {:ok, phone_number_id} <- whatsapp_phone_number_id(settings),
         app_secret_ref <-
           Map.get(settings, "app_secret_ref", "secret://channels/whatsapp/app_secret"),
         {:ok, app_secret} <- Secrets.get_secret(app_secret_ref, secret_context()) do
      payload =
        WhatsApp.Parser.simulated_text_webhook(%{
          from: from,
          phone_number_id: phone_number_id,
          display_phone_number: Map.get(settings, "phone_number_id"),
          waba_id: Map.get(settings, "waba_id"),
          message_id: message_id || "wamid." <> Ecto.UUID.generate(),
          text: text
        })

      raw_body = Jason.encode!(payload)
      signature = whatsapp_webhook_signature(app_secret, raw_body, bad_signature?)
      base = base_url || System.get_env("ALLBERT_WEBHOOK_BASE_URL") || "http://127.0.0.1:4000"

      url =
        String.trim_trailing(base, "/") <> "/webhooks/whatsapp/" <> URI.encode(phone_number_id)

      post_signed_whatsapp_webhook(url, raw_body, signature, bad_signature?)
    end
  end

  defp whatsapp_phone_number_id(settings) do
    case Map.get(settings, "phone_number_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :whatsapp_phone_number_id_not_configured}
    end
  end

  defp whatsapp_webhook_signature(app_secret, raw_body, false) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, app_secret, raw_body), case: :lower)
  end

  defp whatsapp_webhook_signature(_app_secret, _raw_body, true) do
    # Correct shape (64 lowercase hex), wrong bytes: passes the format check so the
    # ingress reaches `secure_compare`, which then rejects it as invalid.
    "sha256=" <> String.duplicate("0", 64)
  end

  defp post_signed_whatsapp_webhook(url, raw_body, signature, bad_signature?) do
    expected = if bad_signature?, do: :deny_401, else: :accept_202

    case Req.post(url,
           headers: [
             {"content-type", "application/json"},
             {"x-hub-signature-256", signature}
           ],
           body: raw_body,
           decode_body: false,
           retry: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, {:webhook_post, status, to_string(body), expected, bad_signature?}}

      {:error, exception} when is_exception(exception) ->
        {:error, {:webhook_post_transport, Exception.message(exception)}}

      {:error, reason} ->
        {:error, {:webhook_post_transport, reason}}
    end
  end

  defp simulate_whatsapp_button!(external_user_id, button_id) do
    with {:ok, settings} <- Channels.channel_settings("whatsapp"),
         payload <-
           WhatsApp.Parser.simulated_button_webhook(%{
             from: external_user_id,
             phone_number_id: Map.get(settings, "phone_number_id"),
             display_phone_number: Map.get(settings, "phone_number_id"),
             waba_id: Map.get(settings, "waba_id"),
             button_id: button_id
           }),
         {:ok, adapter} <-
           WhatsApp.Adapter.start_link(name: nil, req_options: [mode: :stub]),
         result <- WhatsApp.Adapter.simulate_webhook_event(adapter, payload) do
      GenServer.stop(adapter)
      {:ok, {:poll, "whatsapp", result}}
    end
  end

  defp simulate_signal!(aci, message_id, text) do
    aci = normalize_signal_aci!(aci)
    timestamp_ms = signal_message_timestamp(message_id)

    with {:ok, settings} <- Channels.channel_settings("signal"),
         notification <-
           Signal.Parser.simulated_receive_notification(%{
             source_aci: aci,
             timestamp_ms: timestamp_ms,
             text: text
           }),
         {:ok, adapter} <-
           Signal.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <- Signal.Adapter.simulate_daemon_notification(adapter, notification) do
      GenServer.stop(adapter)
      normalize_signal_simulation(result, settings)
    end
  end

  defp simulate_discord!(guild_id, channel_id, external_user_id, thread_channel_id, text) do
    with {:ok, settings} <- Channels.channel_settings("discord"),
         event <-
           Discord.Parser.simulated_message_event(%{
             guild_id: guild_id,
             channel_id: channel_id,
             thread_channel_id: thread_channel_id,
             user_id: external_user_id,
             application_id: Map.get(settings, "application_id"),
             text: text
           }),
         {:ok, adapter} <- Discord.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <-
           Discord.Adapter.simulate_gateway_event(adapter, event, @simulate_gateway_timeout_ms) do
      GenServer.stop(adapter)
      normalize_discord_simulation(result)
    end
  end

  defp simulate_discord_callback!(external_user_id, custom_id) do
    with {:ok, settings} <- Channels.channel_settings("discord"),
         event <-
           %{
             "t" => "INTERACTION_CREATE",
             "d" =>
               %{
                 "id" => "sim_" <> Ecto.UUID.generate(),
                 "token" => "sim_token_" <> Ecto.UUID.generate(),
                 "guild_id" => first_setting(settings, "allowed_guild_ids"),
                 "channel_id" => first_setting(settings, "allowed_channel_ids"),
                 "user" => %{"id" => external_user_id},
                 "data" => %{"custom_id" => custom_id}
               }
               |> compact()
           },
         {:ok, adapter} <- Discord.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <-
           Discord.Adapter.simulate_gateway_event(adapter, event, @simulate_gateway_timeout_ms) do
      GenServer.stop(adapter)
      normalize_discord_simulation(result)
    end
  end

  defp simulate_slack!(channel_id, external_user_id, thread_ts, text) do
    with {:ok, settings} <- Channels.channel_settings("slack"),
         event <-
           Slack.Parser.simulated_event(%{
             team_id: Map.get(settings, "workspace_team_id"),
             channel_id: channel_id,
             thread_ts: thread_ts,
             user_id: external_user_id,
             text: text
           }),
         {:ok, adapter} <- Slack.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <- Slack.Adapter.simulate_socket_envelope(adapter, event) do
      GenServer.stop(adapter)
      normalize_slack_simulation(result)
    end
  end

  defp simulate_slack_callback!(external_user_id, channel_id, action_id) do
    with {:ok, settings} <- Channels.channel_settings("slack"),
         event <-
           Slack.Parser.simulated_interactive(%{
             team_id: Map.get(settings, "workspace_team_id"),
             channel_id: channel_id,
             user_id: external_user_id,
             action_id: action_id
           }),
         {:ok, adapter} <- Slack.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <- Slack.Adapter.simulate_socket_envelope(adapter, event) do
      GenServer.stop(adapter)
      {:ok, {:poll, "slack", result}}
    end
  end

  defp normalize_discord_simulation({:ok, {:processed, event, rendered}}) do
    {:ok, {:simulate, event, Enum.map(rendered, &Map.get(&1, :content, ""))}}
  end

  defp normalize_discord_simulation(other), do: {:ok, {:poll, "discord", other}}

  defp normalize_slack_simulation({:ok, {:processed, event, rendered}}) do
    {:ok, {:simulate, event, Enum.map(rendered, &Map.get(&1, :text, ""))}}
  end

  defp normalize_slack_simulation(other), do: {:ok, {:poll, "slack", other}}

  defp normalize_whatsapp_simulation({:ok, %{processed: processed} = summary})
       when processed > 0 do
    event =
      AllbertAssist.Repo.one(
        from event in AllbertAssist.Channels.Event,
          where: event.channel == "whatsapp",
          order_by: [desc: event.inserted_at],
          limit: 1
      )

    {:ok, {:simulate, event, ["whatsapp processed=#{summary.processed}"]}}
  end

  defp normalize_whatsapp_simulation(other), do: {:ok, {:poll, "whatsapp", other}}

  defp normalize_signal_simulation({:ok, %{processed: processed} = summary}, _settings)
       when processed > 0 do
    event =
      AllbertAssist.Repo.one(
        from event in AllbertAssist.Channels.Event,
          where: event.channel == "signal",
          order_by: [desc: event.inserted_at],
          limit: 1
      )

    {:ok, {:simulate, event, ["signal processed=#{summary.processed}"]}}
  end

  defp normalize_signal_simulation(other, _settings), do: {:ok, {:poll, "signal", other}}

  defp normalize_signal_aci!(aci) do
    aci = Signal.Parser.normalize_aci(aci)

    if Signal.Parser.valid_aci?(aci) do
      aci
    else
      Mix.raise("Signal identity must be an ACI UUID")
    end
  end

  defp signal_message_timestamp(nil), do: System.system_time(:millisecond)

  defp signal_message_timestamp(value) do
    case Integer.parse(to_string(value)) do
      {timestamp, ""} -> timestamp
      _error -> Mix.raise("--message-id must be a Signal timestamp in milliseconds")
    end
  end

  defp mark_simulated_event(event, response, user_id, session_id) do
    Channels.update_event(event, %{
      status: "processed",
      user_id: user_id,
      session_id: session_id,
      thread_id: response_value(response, :thread_id),
      input_signal_id: response_value(response, :input_signal_id),
      trace_id: response_value(response, :trace_id)
    })
  end

  defp simulate_metadata(channel, provider, event, message_id) do
    %{
      channel: channel,
      provider: provider,
      external_event_id: event.external_event_id,
      external_user_id: event.external_user_id,
      external_chat_id: event.external_chat_id,
      external_message_id: message_id
    }
  end

  defp prompt_text("/new " <> text), do: {String.trim(text), true}
  defp prompt_text(text), do: {text, false}

  defp required!(opts, key) do
    case opts[key] do
      value when is_binary(value) and value != "" -> value
      _value -> Mix.raise("--#{String.replace(Atom.to_string(key), "_", "-")} is required")
    end
  end

  defp single_arg!([value], _message), do: value
  defp single_arg!([], message), do: Mix.raise(message)
  defp single_arg!(args, _message), do: Mix.raise("Expected one argument, got: #{inspect(args)}")

  defp parse!(args), do: OptionParser.parse(args, switches: @switches)

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

  defp validate_discord_token_ref("secret://channels/discord/" <> rest) when rest != "",
    do: :ok

  defp validate_discord_token_ref(_token_ref),
    do: Mix.raise("Discord set-token accepts only secret://channels/discord/... refs")

  defp validate_slack_token_ref("secret://channels/slack/" <> rest, _kind) when rest != "",
    do: :ok

  defp validate_slack_token_ref(_token_ref, :bot),
    do: Mix.raise("Slack set-token accepts only secret://channels/slack/... refs")

  defp validate_slack_token_ref(_token_ref, :app),
    do: Mix.raise("Slack set-app-token accepts only secret://channels/slack/... refs")

  defp first_setting(settings, key) do
    case Map.get(settings, key, []) do
      [value | _rest] -> value
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, %{}, []] end)
    |> Map.new()
  end

  defp identity_field(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp credential_status(statuses) when is_map(statuses) do
    statuses
    |> Map.values()
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
    |> Enum.join(",")
  end

  defp credential_status(_statuses), do: "unknown"

  defp diagnostic_status([]), do: "none"

  defp diagnostic_status(diagnostics) do
    diagnostics
    |> Enum.map(&to_string/1)
    |> Enum.join(",")
  end

  defp setup_fields(fields) do
    fields
    |> Enum.map(fn field ->
      "#{field.name}=#{setup_field_status(field)}"
    end)
    |> Enum.join(",")
  end

  defp setup_field_status(%{required?: true, configured?: true}), do: "configured"
  defp setup_field_status(%{required?: true, configured?: false}), do: "missing"
  defp setup_field_status(%{required?: false, configured?: true}), do: "configured_optional"
  defp setup_field_status(%{required?: false, configured?: false}), do: "optional"

  defp secret_fields(fields) do
    fields
    |> Enum.map(fn field ->
      "#{field.name}=#{field.status}#{secret_required_suffix(field)}"
    end)
    |> Enum.join(",")
  end

  defp secret_required_suffix(%{required?: true}), do: ""
  defp secret_required_suffix(%{required?: false}), do: "_optional"

  defp maybe_print_release_decision(%{release_decision: %{live_use_allowed?: true}}), do: :ok

  defp maybe_print_release_decision(%{release_decision: %{decision: decision}})
       when is_binary(decision) do
    Mix.shell().info("Release decision: #{decision}")
  end

  defp maybe_print_release_decision(_value), do: :ok

  defp maybe_print_doctor(%{doctor: doctor}) when is_map(doctor) do
    Mix.shell().info("Doctor: #{doctor_status(doctor)}")
  end

  defp maybe_print_doctor(_channel), do: :ok

  defp maybe_print_doctor_field(_label, nil), do: :ok
  defp maybe_print_doctor_field(label, value), do: Mix.shell().info("#{label}=#{value}")

  defp doctor_status(doctor) do
    Map.get(doctor, "status", Map.get(doctor, :status, "unknown"))
  end

  defp identity_link_line(link, prefix) do
    "#{prefix} #{link.link_id} user=#{link.user_id} channel=#{link.channel} receiver=#{link.receiver_account_ref} external_user=#{link.external_user_id}"
  end

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp context do
    ContextBuilder.cli_context(surface: "mix allbert.channels")
  end

  defp secret_context,
    do: ContextBuilder.cli_context(surface: "mix allbert.channels", audit?: false)
end
