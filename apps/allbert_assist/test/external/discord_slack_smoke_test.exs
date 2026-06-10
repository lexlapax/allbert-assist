defmodule AllbertAssist.External.DiscordSlackSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial
  @moduletag :home_fs_serial

  if System.get_env("ALLBERT_DISCORD_SLACK_EXTERNAL_SMOKE") != "1" do
    @moduletag skip:
                 "set ALLBERT_DISCORD_SLACK_EXTERNAL_SMOKE=1 to run the real Discord/Slack channel smoke"
  end

  alias AllbertAssist.Channels.Discord.Client, as: DiscordClient
  alias AllbertAssist.Channels.Slack.Client, as: SlackClient
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  @required_env [
    "ALLBERT_SLACK_BOT_TOKEN",
    "ALLBERT_SLACK_CHANNEL_ID",
    "ALLBERT_DISCORD_BOT_TOKEN",
    "ALLBERT_DISCORD_CHANNEL_ID"
  ]

  setup_all do
    missing = Enum.filter(@required_env, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      flunk("missing required Discord/Slack smoke env vars: #{Enum.join(missing, ", ")}")
    end

    home =
      System.get_env("ALLBERT_HOME") ||
        Path.join(System.tmp_dir!(), "allbert-discord-slack-smoke")

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    Mix.Task.reenable("ecto.migrate.allbert")
    Mix.Task.run("ecto.migrate.allbert", ["--quiet"])

    put_secret!("secret://channels/slack/bot_token", System.fetch_env!("ALLBERT_SLACK_BOT_TOKEN"))

    put_secret!(
      "secret://channels/discord/bot_token",
      System.fetch_env!("ALLBERT_DISCORD_BOT_TOKEN")
    )

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
    end)

    %{
      home: home,
      slack_channel_id: System.fetch_env!("ALLBERT_SLACK_CHANNEL_ID"),
      discord_channel_id: System.fetch_env!("ALLBERT_DISCORD_CHANNEL_ID"),
      discord_guild_id: System.get_env("ALLBERT_DISCORD_GUILD_ID")
    }
  end

  test "real Slack and Discord delivery preserves thread placement and echo metadata", context do
    started_at = DateTime.utc_now()
    marker = "Allbert v0.52 external smoke #{DateTime.to_iso8601(started_at)}"

    assert {:ok, slack_auth} =
             SlackClient.auth_test("secret://channels/slack/bot_token", mode: :real)

    slack_team_id = Map.get(slack_auth, "team_id", "unknown")

    assert {:ok, slack_parent} =
             SlackClient.chat_post_message(
               "secret://channels/slack/bot_token",
               %{
                 channel: context.slack_channel_id,
                 text: "#{marker} parent",
                 unfurl_links: false,
                 unfurl_media: false
               },
               mode: :real
             )

    assert {:ok, slack_reply} =
             SlackClient.chat_post_message(
               "secret://channels/slack/bot_token",
               %{
                 channel: context.slack_channel_id,
                 text: "#{marker} Slack thread reply",
                 thread_ts: slack_parent["ts"],
                 unfurl_links: false,
                 unfurl_media: false
               },
               mode: :real
             )

    assert slack_reply["message"]["thread_ts"] in [slack_parent["ts"], slack_reply["ts"]]

    assert {:ok, discord_bot} =
             DiscordClient.users_me("secret://channels/discord/bot_token", mode: :real)

    assert {:ok, discord_parent} =
             DiscordClient.create_message(
               "secret://channels/discord/bot_token",
               context.discord_channel_id,
               %{content: "#{marker} parent", allowed_mentions: %{parse: []}},
               mode: :real
             )

    assert {:ok, discord_reply} =
             DiscordClient.create_message(
               "secret://channels/discord/bot_token",
               context.discord_channel_id,
               %{
                 content: "#{marker} Discord reply",
                 message_reference: %{message_id: discord_parent["id"]},
                 allowed_mentions: %{parse: []}
               },
               mode: :real
             )

    assert get_in(discord_reply, ["message_reference", "message_id"]) == discord_parent["id"]

    assert {:ok, thread} = Conversations.create_general_thread("external-smoke", "v0.52 smoke")
    assert {:ok, slack_assistant} = Conversations.append_assistant_message(thread, "Slack sent")

    assert {:ok, discord_assistant} =
             Conversations.append_assistant_message(thread, "Discord sent")

    slack_receiver = "slack:team:#{slack_team_id}"

    assert {:ok, _ref} =
             ChannelThread.record_message_ref(%{
               channel: "slack",
               receiver_account_ref: slack_receiver,
               provider_thread_ref: %{
                 team_id: slack_team_id,
                 channel_id: context.slack_channel_id,
                 thread_ts: slack_parent["ts"]
               },
               canonical_thread_id: thread.id,
               canonical_message_id: slack_assistant.id,
               provider_message_id: slack_reply["ts"],
               direction: :out
             })

    discord_receiver =
      "discord:app:#{discord_bot["id"]}:guild:#{context.discord_guild_id || "unknown"}"

    assert {:ok, _ref} =
             ChannelThread.record_message_ref(%{
               channel: "discord",
               receiver_account_ref: discord_receiver,
               provider_thread_ref: %{
                 application_id: discord_bot["id"],
                 guild_id: context.discord_guild_id || "unknown",
                 channel_id: context.discord_channel_id,
                 provider_thread_root: context.discord_channel_id
               },
               canonical_thread_id: thread.id,
               canonical_message_id: discord_assistant.id,
               provider_message_id: discord_reply["id"],
               direction: :out
             })

    assert ChannelThread.echo?(%{
             channel: "slack",
             receiver_account_ref: slack_receiver,
             provider_message_id: slack_reply["ts"]
           })

    assert ChannelThread.echo?(%{
             channel: "discord",
             receiver_account_ref: discord_receiver,
             provider_message_id: discord_reply["id"]
           })

    evidence_path =
      write_evidence!(context.home, started_at, %{
        slack: %{
          team_id: slack_team_id,
          channel_id: context.slack_channel_id,
          parent_ts: slack_parent["ts"],
          reply_ts: slack_reply["ts"],
          echo_suppression_recorded?: true
        },
        discord: %{
          bot_id: discord_bot["id"],
          channel_id: context.discord_channel_id,
          parent_message_id: discord_parent["id"],
          reply_message_id: discord_reply["id"],
          echo_suppression_recorded?: true
        }
      })

    IO.puts("discord_slack external smoke evidence: #{evidence_path}")
  end

  defp write_evidence!(home, started_at, provider_evidence) do
    evidence_dir = Path.join(home, "release_evidence/v052")
    File.mkdir_p!(evidence_dir)

    evidence = %{
      gate: "mix allbert.test external-smoke -- discord_slack",
      version: "v0.52",
      status: "passed",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      providers: provider_evidence,
      secret_material: "redacted; tokens stored only through Settings Central secret refs"
    }

    path = Path.join(evidence_dir, "external-smoke-#{DateTime.to_unix(started_at)}.json")
    File.write!(path, Jason.encode!(evidence, pretty: true))
    path
  end

  defp put_secret!(secret_ref, value) do
    assert {:ok, _secret} = Secrets.put_secret(secret_ref, value, %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
