defmodule AllbertAssist.External.MessagingChannelInboundSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial
  @moduletag :home_fs_serial
  @moduletag :app_env_serial

  if System.get_env("ALLBERT_MESSAGING_CHANNEL_INBOUND_EXTERNAL_SMOKE") != "1" do
    @moduletag skip:
                 "set ALLBERT_MESSAGING_CHANNEL_INBOUND_EXTERNAL_SMOKE=1 to run the real messaging-channel inbound smoke"
  end

  alias AllbertAssist.Channels.Discord.Adapter, as: DiscordAdapter
  alias AllbertAssist.Channels.Discord.Client, as: DiscordClient
  alias AllbertAssist.Channels.Slack.Adapter, as: SlackAdapter
  alias AllbertAssist.Channels.Slack.Client, as: SlackClient
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Discord, as: DiscordPlugin
  alias AllbertAssist.Plugins.Slack, as: SlackPlugin
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace

  @required_env [
    "ALLBERT_SLACK_BOT_TOKEN",
    "ALLBERT_SLACK_APP_TOKEN",
    "ALLBERT_SLACK_CHANNEL_ID",
    "ALLBERT_SLACK_USER_ID",
    "ALLBERT_DISCORD_BOT_TOKEN",
    "ALLBERT_DISCORD_APPLICATION_ID",
    "ALLBERT_DISCORD_GUILD_ID",
    "ALLBERT_DISCORD_CHANNEL_ID",
    "ALLBERT_DISCORD_USER_ID"
  ]

  setup_all do
    missing = Enum.filter(@required_env, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      flunk("missing required Discord/Slack inbound smoke env vars: #{Enum.join(missing, ", ")}")
    end

    home =
      System.get_env("ALLBERT_HOME") ||
        Path.join(System.tmp_dir!(), "allbert-discord-slack-inbound-smoke")

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()
    parent = self()

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    assert {:ok, "allbert.discord"} = PluginRegistry.register_module(DiscordPlugin)
    assert {:ok, "allbert.slack"} = PluginRegistry.register_module(SlackPlugin)
    Fragments.clear_cache()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})
        {:ok, %{message: "Inbound smoke received: #{request.text}", status: :completed}}
      end
    )

    Mix.Task.reenable("ecto.migrate.allbert")
    Mix.Task.run("ecto.migrate.allbert", ["--quiet"])

    put_secret!("secret://channels/slack/bot_token", System.fetch_env!("ALLBERT_SLACK_BOT_TOKEN"))
    put_secret!("secret://channels/slack/app_token", System.fetch_env!("ALLBERT_SLACK_APP_TOKEN"))

    put_secret!(
      "secret://channels/discord/bot_token",
      System.fetch_env!("ALLBERT_DISCORD_BOT_TOKEN")
    )

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
      timeout_ms: timeout_ms(),
      slack_channel_id: System.fetch_env!("ALLBERT_SLACK_CHANNEL_ID"),
      slack_user_id: System.fetch_env!("ALLBERT_SLACK_USER_ID"),
      discord_application_id: System.fetch_env!("ALLBERT_DISCORD_APPLICATION_ID"),
      discord_guild_id: System.fetch_env!("ALLBERT_DISCORD_GUILD_ID"),
      discord_channel_id: System.fetch_env!("ALLBERT_DISCORD_CHANNEL_ID"),
      discord_user_id: System.fetch_env!("ALLBERT_DISCORD_USER_ID")
    }
  end

  test "real Gateway and Socket Mode sessions deliver operator-sent inbound messages", context do
    started_at = DateTime.utc_now()
    marker = "allbert-v052-inbound-#{DateTime.to_unix(started_at)}"

    assert {:ok, slack_auth} =
             SlackClient.auth_test("secret://channels/slack/bot_token", mode: :real)

    slack_team_id = Map.fetch!(slack_auth, "team_id")
    slack_bot_user_id = Map.fetch!(slack_auth, "user_id")

    assert {:ok, discord_bot} =
             DiscordClient.users_me("secret://channels/discord/bot_token", mode: :real)

    configure_slack!(context, slack_team_id)
    configure_discord!(context)

    assert {:ok, discord_adapter} = DiscordAdapter.start_link(name: nil)
    assert {:ok, slack_adapter} = SlackAdapter.start_link(name: nil)

    assert :ok =
             wait_for_adapter_state(discord_adapter, context.timeout_ms, fn state ->
               state.last_ready != nil
             end)

    assert :ok =
             wait_for_adapter_state(slack_adapter, context.timeout_ms, fn state ->
               state.last_hello != nil
             end)

    IO.puts("""
    messaging_channel_inbound marker: #{marker}
    Send from mapped Discord user #{context.discord_user_id} in guild #{context.discord_guild_id}/channel #{context.discord_channel_id}:
      <@#{discord_bot["id"]}> #{marker} discord
    Send from mapped Slack user #{context.slack_user_id} in channel #{context.slack_channel_id}:
      <@#{slack_bot_user_id}> #{marker} slack
    Waiting up to #{context.timeout_ms}ms for provider-delivered inbound events.
    """)

    requests = wait_for_runtime_requests(["discord", "slack"], marker, context.timeout_ms)

    evidence_path =
      write_evidence!(context.home, started_at, %{
        marker: marker,
        timeout_ms: context.timeout_ms,
        discord: %{
          gateway_ready?: true,
          bot_user_id: discord_bot["id"],
          application_id: context.discord_application_id,
          guild_id: context.discord_guild_id,
          channel_id: context.discord_channel_id,
          mapped_user_id: context.discord_user_id,
          runtime_request?: Map.has_key?(requests, "discord"),
          runtime_text: requests["discord"].text
        },
        slack: %{
          socket_mode_hello?: true,
          team_id: slack_team_id,
          bot_user_id: slack_bot_user_id,
          channel_id: context.slack_channel_id,
          mapped_user_id: context.slack_user_id,
          runtime_request?: Map.has_key?(requests, "slack"),
          runtime_text: requests["slack"].text
        },
        manual_followups_required: [
          "Discord button approve/deny from the mapped clicker",
          "Slack button approve/deny from the mapped clicker",
          "unmapped or non-allowlisted callback rejection before confirmation resolution"
        ]
      })

    IO.puts("messaging_channel_inbound external smoke evidence: #{evidence_path}")
  end

  defp configure_slack!(context, slack_team_id) do
    put_setting!("channels.slack.bot_token_ref", "secret://channels/slack/bot_token")
    put_setting!("channels.slack.app_token_ref", "secret://channels/slack/app_token")
    put_setting!("channels.slack.workspace_team_id", slack_team_id)
    put_setting!("channels.slack.allowed_channel_ids", [context.slack_channel_id])

    put_setting!("channels.slack.identity_map", [
      %{
        "external_user_id" => context.slack_user_id,
        "user_id" => "external-smoke",
        "enabled" => true
      }
    ])

    put_setting!("channels.slack.enabled", true)
  end

  defp configure_discord!(context) do
    put_setting!("channels.discord.bot_token_ref", "secret://channels/discord/bot_token")
    put_setting!("channels.discord.application_id", context.discord_application_id)
    put_setting!("channels.discord.allowed_guild_ids", [context.discord_guild_id])
    put_setting!("channels.discord.allowed_channel_ids", [context.discord_channel_id])

    put_setting!("channels.discord.gateway_intents", [
      "guild_messages",
      "direct_messages",
      "message_content"
    ])

    put_setting!("channels.discord.identity_map", [
      %{
        "external_user_id" => context.discord_user_id,
        "user_id" => "external-smoke",
        "enabled" => true
      }
    ])

    put_setting!("channels.discord.enabled", true)
  end

  defp wait_for_adapter_state(adapter, timeout_ms, predicate) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_adapter_state(adapter, deadline, predicate)
  end

  defp do_wait_for_adapter_state(adapter, deadline, predicate) do
    state = :sys.get_state(adapter)

    cond do
      predicate.(state) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for live channel session readiness")

      true ->
        Process.sleep(250)
        do_wait_for_adapter_state(adapter, deadline, predicate)
    end
  end

  defp wait_for_runtime_requests(channels, marker, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_runtime_requests(MapSet.new(channels), marker, deadline, %{})
  end

  defp do_wait_for_runtime_requests(expected, marker, deadline, found) do
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
              Map.put(found, channel, request)
            )
          else
            do_wait_for_runtime_requests(expected, marker, deadline, found)
          end
      after
        remaining ->
          flunk(
            "timed out waiting for inbound runtime requests from #{inspect(MapSet.to_list(expected))}"
          )
      end
    end
  end

  defp matching_request?(request, expected, marker) do
    channel = to_string(Map.get(request, :channel))
    text = to_string(Map.get(request, :text))

    MapSet.member?(expected, channel) and String.contains?(text, marker)
  end

  defp write_evidence!(home, started_at, evidence) do
    evidence_dir = Path.join(home, "release_evidence/v052")
    File.mkdir_p!(evidence_dir)

    body =
      Map.merge(evidence, %{
        gate: "mix allbert.test external-smoke -- messaging_channel_inbound",
        version: "v0.52",
        status: "passed",
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        started_at: DateTime.to_iso8601(started_at),
        secret_material: "redacted; tokens stored only through Settings Central secret refs"
      })

    path =
      Path.join(
        evidence_dir,
        "external-smoke-messaging-inbound-#{DateTime.to_unix(started_at)}.json"
      )

    File.write!(path, Jason.encode!(body, pretty: true))
    path
  end

  defp put_secret!(secret_ref, value) do
    assert {:ok, _secret} = Secrets.put_secret(secret_ref, value, %{audit?: false})
  end

  defp put_setting!(key, value) do
    assert {:ok, _setting} = Settings.put(key, value, %{audit?: false})
  end

  defp timeout_ms do
    case System.get_env("ALLBERT_MESSAGING_CHANNEL_INBOUND_TIMEOUT_MS") do
      nil -> 120_000
      value -> String.to_integer(value)
    end
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
