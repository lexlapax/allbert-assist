defmodule Mix.Tasks.Allbert.Channels do
  @moduledoc """
  Inspect and operate local channel adapters.

  ## Usage

      mix allbert.channels list
      mix allbert.channels show telegram
      mix allbert.channels telegram set-token TOKEN
      mix allbert.channels telegram map --external-user EXTERNAL --user USER
      mix allbert.channels telegram unmap --external-user EXTERNAL
      mix allbert.channels telegram simulate --external-user EXTERNAL --chat CHAT "prompt"
      mix allbert.channels telegram poll-once
      mix allbert.channels email set-password --type imap PASSWORD
      mix allbert.channels email set-password --type smtp PASSWORD
      mix allbert.channels email map --external-user EMAIL --user USER
      mix allbert.channels email unmap --external-user EMAIL
      mix allbert.channels email simulate --external-user EMAIL [--new-thread] "prompt"
      mix allbert.channels email poll-once
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Discord
  alias AllbertAssist.Channels.Email
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.Telegram
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  @shortdoc "Inspect and operate local channel adapters"

  @switches [
    chat: :string,
    channel: :string,
    custom_id: :string,
    external_user: :string,
    guild: :string,
    new_thread: :boolean,
    thread_channel: :string,
    type: :string,
    user: :string
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list"]) do
    with {:ok, response} <- completed_action("list_channels", %{}) do
      {:ok, {:list, response.channels}}
    end
  end

  defp dispatch(["show", channel]) do
    with {:ok, response} <- completed_action("show_channel", %{channel: channel}) do
      {:ok, {:show, response.channel}}
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

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.channels list
      mix allbert.channels show telegram|email
      mix allbert.channels telegram set-token TOKEN
      mix allbert.channels telegram map --external-user EXTERNAL --user USER
      mix allbert.channels telegram unmap --external-user EXTERNAL
      mix allbert.channels telegram simulate --external-user EXTERNAL --chat CHAT "prompt"
      mix allbert.channels telegram poll-once
      mix allbert.channels email set-password --type imap|smtp PASSWORD
      mix allbert.channels email map --external-user EMAIL --user USER
      mix allbert.channels email unmap --external-user EMAIL
      mix allbert.channels email simulate --external-user EMAIL [--new-thread] "prompt"
      mix allbert.channels email poll-once
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
    """)
  end

  defp print_result({:ok, {:list, channels}}) do
    Enum.each(channels, fn channel ->
      Mix.shell().info(
        "#{channel.channel} provider=#{channel.provider} enabled=#{channel.enabled} identities=#{channel.identity_count} credentials=#{credential_status(channel.credential_status)}"
      )
    end)
  end

  defp print_result({:ok, {:show, channel}}) do
    Mix.shell().info("Channel: #{channel.channel}")
    Mix.shell().info("Provider: #{channel.provider}")
    Mix.shell().info("Enabled: #{channel.enabled}")
    Mix.shell().info("Identities: #{channel.identity_count}")
    Mix.shell().info("Credentials: #{credential_status(channel.credential_status)}")
    maybe_print_doctor(channel)
    Mix.shell().info("Last event: #{inspect(channel.last_event)}")
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

    Mix.shell().info("gateway=#{Map.get(result, :gateway_status)}")
    Mix.shell().info("bot=#{Map.get(result, :bot_username, "unknown")}")
  end

  defp print_result({:error, reason}) do
    Mix.raise("Channels command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
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
         result <- Discord.Adapter.simulate_gateway_event(adapter, event) do
      GenServer.stop(adapter)
      normalize_discord_simulation(result)
    end
  end

  defp simulate_discord_callback!(external_user_id, custom_id) do
    event = %{
      "t" => "INTERACTION_CREATE",
      "d" => %{
        "id" => "sim_" <> Ecto.UUID.generate(),
        "user" => %{"id" => external_user_id},
        "data" => %{"custom_id" => custom_id}
      }
    }

    with {:ok, adapter} <- Discord.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <- Discord.Adapter.simulate_gateway_event(adapter, event) do
      GenServer.stop(adapter)
      {:ok, {:poll, "discord", result}}
    end
  end

  defp normalize_discord_simulation({:ok, {:processed, event, rendered}}) do
    {:ok, {:simulate, event, Enum.map(rendered, &Map.get(&1, :content, ""))}}
  end

  defp normalize_discord_simulation(other), do: {:ok, {:poll, "discord", other}}

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

  defp identity_field(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp credential_status(statuses) when is_map(statuses) do
    statuses
    |> Map.values()
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
    |> Enum.join(",")
  end

  defp credential_status(_statuses), do: "unknown"

  defp maybe_print_doctor(%{doctor: doctor}) when is_map(doctor) do
    Mix.shell().info("Doctor: #{doctor_status(doctor)}")
  end

  defp maybe_print_doctor(_channel), do: :ok

  defp doctor_status(doctor) do
    Map.get(doctor, "status", Map.get(doctor, :status, "unknown"))
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp context do
    %{
      actor: "local",
      channel: :cli,
      request: %{channel: :cli, user_id: "local", operator_id: "local"}
    }
  end

  defp secret_context, do: %{actor: "local", channel: :cli, audit?: false}
end
