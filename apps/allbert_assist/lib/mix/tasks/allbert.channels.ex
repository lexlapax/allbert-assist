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
      mix allbert.channels email simulate --external-user EMAIL "prompt"
      mix allbert.channels email poll-once
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Email
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.Telegram
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  @shortdoc "Inspect and operate local channel adapters"

  @switches [
    chat: :string,
    external_user: :string,
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
      single_arg!(args, "Prompt is required")
    )
  end

  defp dispatch(["email", "poll-once"]) do
    {:ok, {:poll, "email", Email.Adapter.poll_once()}}
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
      mix allbert.channels email simulate --external-user EMAIL "prompt"
      mix allbert.channels email poll-once
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
    Mix.shell().info("Last event: #{inspect(channel.last_event)}")
  end

  defp print_result({:ok, {:secret, channel, secret_name}}) do
    Mix.shell().info("#{channel} #{secret_name}=stored")
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

  defp simulate_email!(external_user_id, text) do
    with {:ok, settings} <- Channels.channel_settings("email"),
         {:ok, user_id} <-
           Identity.resolve("email", external_user_id, Map.get(settings, "identity_map", [])),
         session_id <- Channels.derive_session_id("email", external_user_id, nil),
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
             text: text,
             channel: "email",
             user_id: user_id,
             operator_id: user_id,
             session_id: session_id,
             metadata: simulate_metadata("email", "email_imap", event, nil)
           }),
         {:ok, _subject, body, _html} <- Email.Renderer.render_response(response),
         {:ok, event} <- mark_simulated_event(event, response, user_id, session_id) do
      {:ok, {:simulate, event, [body]}}
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

  defp identity_field(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp credential_status(statuses) when is_map(statuses) do
    statuses
    |> Map.values()
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
    |> Enum.join(",")
  end

  defp credential_status(_statuses), do: "unknown"

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
