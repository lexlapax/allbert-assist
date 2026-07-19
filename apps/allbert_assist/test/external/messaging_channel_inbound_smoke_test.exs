defmodule AllbertAssist.External.MessagingChannelInboundSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial
  # The test waits for an operator to send a real inbound message; ExUnit's
  # default per-test timeout is 60s, which would kill the wait early. Let the
  # internal deadline (ALLBERT_MESSAGING_CHANNEL_INBOUND_TIMEOUT_MS) govern.
  @moduletag timeout: :infinity

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
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.TestSupport.ShippedRegistries
  alias AllbertAssist.Trace
  alias Ecto.Adapters.SQL.Sandbox

  # Per-provider required env. Only the targeted providers
  # (ALLBERT_SMOKE_PROVIDERS, default both) are required, configured, and
  # connected, so a Discord-only or Slack-only operator can validate one provider
  # without standing up the other.
  @discord_required [
    "ALLBERT_DISCORD_BOT_TOKEN",
    "ALLBERT_DISCORD_APPLICATION_ID",
    "ALLBERT_DISCORD_GUILD_ID",
    "ALLBERT_DISCORD_CHANNEL_ID",
    "ALLBERT_DISCORD_USER_ID"
  ]
  @slack_required [
    "ALLBERT_SLACK_BOT_TOKEN",
    "ALLBERT_SLACK_APP_TOKEN",
    "ALLBERT_SLACK_CHANNEL_ID",
    "ALLBERT_SLACK_USER_ID"
  ]

  setup_all do
    providers = targeted_providers()

    required =
      if("discord" in providers, do: @discord_required, else: []) ++
        if "slack" in providers, do: @slack_required, else: []

    missing = Enum.filter(required, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      flunk(
        "missing required inbound smoke env vars for providers #{inspect(providers)}: #{Enum.join(missing, ", ")}"
      )
    end

    home =
      System.get_env("ALLBERT_HOME") ||
        Path.join(System.tmp_dir!(), "allbert-discord-slack-inbound-smoke")

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    if "discord" in providers, do: {:ok, _} = PluginRegistry.register_module(DiscordPlugin)
    if "slack" in providers, do: {:ok, _} = PluginRegistry.register_module(SlackPlugin)
    Fragments.clear_cache()

    # NOTE: the agent_runner that notifies the waiter is installed in `setup`
    # (per-test), NOT here — setup_all runs in a different process, so capturing
    # `self()` here would send the runtime notification to the wrong process and
    # the test's receive would never see it.

    Mix.Task.reenable("ecto.migrate.allbert")
    Mix.Task.run("ecto.migrate.allbert", ["--quiet"])

    if "slack" in providers do
      put_secret!(
        "secret://channels/slack/bot_token",
        System.fetch_env!("ALLBERT_SLACK_BOT_TOKEN")
      )

      put_secret!(
        "secret://channels/slack/app_token",
        System.fetch_env!("ALLBERT_SLACK_APP_TOKEN")
      )
    end

    if "discord" in providers do
      put_secret!(
        "secret://channels/discord/bot_token",
        System.fetch_env!("ALLBERT_DISCORD_BOT_TOKEN")
      )
    end

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      ShippedRegistries.restore!()
      Fragments.clear_cache()
    end)

    %{
      home: home,
      providers: providers,
      timeout_ms: timeout_ms(),
      slack_channel_id: System.get_env("ALLBERT_SLACK_CHANNEL_ID"),
      slack_user_id: System.get_env("ALLBERT_SLACK_USER_ID"),
      discord_application_id: System.get_env("ALLBERT_DISCORD_APPLICATION_ID"),
      discord_guild_id: System.get_env("ALLBERT_DISCORD_GUILD_ID"),
      discord_channel_id: System.get_env("ALLBERT_DISCORD_CHANNEL_ID"),
      discord_user_id: System.get_env("ALLBERT_DISCORD_USER_ID")
    }
  end

  setup do
    # Adapters (spawned processes) write channel_events to the owned home DB.
    # test_helper puts the Repo in :manual sandbox mode; check out a shared
    # connection so the test process AND the adapter processes can use it.
    # Large ownership_timeout — this test holds the connection while waiting (up
    # to 5 min) for a real operator message; the default 120s ownership timeout
    # would drop the connection mid-wait and silently break inbound DB writes.
    # Use 1h, comfortably above ALLBERT_MESSAGING_CHANNEL_INBOUND_TIMEOUT_MS.
    :ok = Sandbox.checkout(Repo, ownership_timeout: 3_600_000)
    Sandbox.mode(Repo, {:shared, self()})

    # Install the agent_runner HERE (setup runs in the test process) so the
    # {:runtime_request, _} notification reaches the process that waits on it.
    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})
        {:ok, %{message: "Inbound smoke received: #{request.text}", status: :completed}}
      end
    )

    :ok
  end

  test "real Gateway and Socket Mode sessions deliver operator-sent inbound messages", context do
    started_at = DateTime.utc_now()
    # Allow the marker to be supplied via env so the operator/agent knows the
    # exact text to send up front. stdout is buffered when captured (non-TTY), so
    # the printed marker may not be visible until the process exits; a supplied
    # marker removes that dependency. Falls back to a timestamped default.
    marker =
      case System.get_env("ALLBERT_SMOKE_MARKER") do
        value when value in [nil, ""] -> "allbert-v052-inbound-#{DateTime.to_unix(started_at)}"
        value -> value
      end

    discord? = "discord" in context.providers
    slack? = "slack" in context.providers

    discord_bot = if discord?, do: start_discord!(context), else: nil

    {slack_team_id, slack_bot_user_id} =
      if slack?, do: start_slack!(context), else: {nil, nil}

    print_marker_instructions(context, marker, discord_bot, slack_bot_user_id)

    expected_channels =
      [] ++ if(discord?, do: ["discord"], else: []) ++ if(slack?, do: ["slack"], else: [])

    requests =
      wait_for_runtime_requests(expected_channels, marker, context.timeout_ms, context.home)

    discord_evidence =
      if discord? do
        %{
          gateway_ready?: true,
          bot_user_id: discord_bot["id"],
          application_id: context.discord_application_id,
          guild_id: context.discord_guild_id,
          channel_id: context.discord_channel_id,
          mapped_user_id: context.discord_user_id,
          runtime_request?: Map.has_key?(requests, "discord"),
          runtime_text: requests["discord"].text
        }
      else
        :skipped
      end

    slack_evidence =
      if slack? do
        %{
          socket_mode_hello?: true,
          team_id: slack_team_id,
          bot_user_id: slack_bot_user_id,
          channel_id: context.slack_channel_id,
          mapped_user_id: context.slack_user_id,
          runtime_request?: Map.has_key?(requests, "slack"),
          runtime_text: requests["slack"].text
        }
      else
        :skipped
      end

    evidence_path =
      write_evidence!(context.home, started_at, %{
        marker: marker,
        providers: context.providers,
        timeout_ms: context.timeout_ms,
        discord: discord_evidence,
        slack: slack_evidence,
        manual_followups_required: [
          "button approve/deny from the mapped clicker",
          "unmapped or non-allowlisted callback rejection before confirmation resolution"
        ]
      })

    IO.puts("messaging_channel_inbound external smoke evidence: #{evidence_path}")
  end

  defp start_discord!(context) do
    assert {:ok, discord_bot} =
             DiscordClient.users_me("secret://channels/discord/bot_token", mode: :real)

    configure_discord!(context)
    assert {:ok, discord_adapter} = DiscordAdapter.start_link(name: nil)

    assert :ok =
             wait_for_adapter_state(discord_adapter, context.timeout_ms, fn state ->
               state.last_ready != nil
             end)

    discord_bot
  end

  defp start_slack!(context) do
    assert {:ok, slack_auth} =
             SlackClient.auth_test("secret://channels/slack/bot_token", mode: :real)

    slack_team_id = Map.fetch!(slack_auth, "team_id")
    slack_bot_user_id = Map.fetch!(slack_auth, "user_id")

    configure_slack!(context, slack_team_id)
    assert {:ok, slack_adapter} = SlackAdapter.start_link(name: nil)

    assert :ok =
             wait_for_adapter_state(slack_adapter, context.timeout_ms, fn state ->
               state.last_hello != nil
             end)

    {slack_team_id, slack_bot_user_id}
  end

  defp print_marker_instructions(context, marker, discord_bot, slack_bot_user_id) do
    discord_line =
      if discord_bot do
        """
        Send from mapped Discord user #{context.discord_user_id} in guild #{context.discord_guild_id}/channel #{context.discord_channel_id}:
          <@#{discord_bot["id"]}> #{marker} discord
        """
      else
        ""
      end

    slack_line =
      if slack_bot_user_id do
        """
        Send from mapped Slack user #{context.slack_user_id} in channel #{context.slack_channel_id}:
          <@#{slack_bot_user_id}> #{marker} slack
        """
      else
        ""
      end

    IO.puts("""
    messaging_channel_inbound marker: #{marker}
    #{discord_line}#{slack_line}Waiting up to #{context.timeout_ms}ms for provider-delivered inbound events.
    """)
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
          # No matching runtime request arrived. Dump what the adapters actually
          # recorded (channel_events: received/rejected + reason) so a silent miss
          # is diagnosable despite buffered stdout. Uses the shared sandbox
          # connection, so it sees rows the adapter processes inserted.
          diag = dump_inbound_diagnostics(home)

          flunk(
            "timed out waiting for inbound runtime requests from " <>
              "#{inspect(MapSet.to_list(expected))}\n--- recorded channel_events ---\n#{diag}"
          )
      end
    end
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
        "(none — the adapters recorded NO inbound channel_events; the Gateway/" <>
          "Socket Mode delivered nothing the adapter processed — check intents, " <>
          "channel/guild allowlist match, and that the message reached the channel)"
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

  defp matching_request?(request, expected, marker) do
    channel = to_string(Map.get(request, :channel))
    text = to_string(Map.get(request, :text))

    MapSet.member?(expected, channel) and String.contains?(text, marker)
  end

  defp targeted_providers do
    case System.get_env("ALLBERT_SMOKE_PROVIDERS") do
      value when value in [nil, ""] ->
        ["discord", "slack"]

      value ->
        value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp write_evidence!(home, started_at, evidence) do
    evidence_dir = Path.join(home, "release_evidence/v052")
    File.mkdir_p!(evidence_dir)

    body =
      Map.merge(evidence, %{
        gate:
          "mix allbert.test external-smoke -- #{Enum.join(["inbound" | evidence.providers], "_")}",
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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
