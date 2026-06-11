defmodule AllbertAssist.Security.V052ChannelPackEvalTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :security_eval_serial
  @moduletag :app_env_serial
  @moduletag :global_process_serial

  setup {Req.Test, :verify_on_exit!}

  alias AllbertAssist.Approval.Handoff
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.ConfirmationCallback
  alias AllbertAssist.Channels.Discord.Adapter, as: DiscordAdapter
  alias AllbertAssist.Channels.Discord.Client, as: DiscordClient
  alias AllbertAssist.Channels.Discord.Parser, as: DiscordParser
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.Slack.Adapter, as: SlackAdapter
  alias AllbertAssist.Channels.Slack.Client, as: SlackClient
  alias AllbertAssist.Channels.Slack.Parser, as: SlackParser
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Conversations.UnifiedHistory
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugin.Validator
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace

  defmodule MissingPrimitivesPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "v052.missing_primitives"

    @impl true
    def display_name, do: "v0.52 Missing Primitives"

    @impl true
    def version, do: "0.52.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels, do: [%{channel_id: "missing_primitives", threading: :flat}]
  end

  defmodule MissingThreadingPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "v052.missing_threading"

    @impl true
    def display_name, do: "v0.52 Missing Threading"

    @impl true
    def version, do: "0.52.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels, do: [%{channel_id: "missing_threading", primitives: [:typed_command, :list]}]
  end

  @eval_groups [
    ingress: [
      "discord-slack-spoofing-001",
      "team-channel-replay-001",
      "group-leakage-001",
      "channel-inbound-permission-enforcement-001",
      "dm-vs-workspace-auth-001",
      "discord-interactions-signature-verification-001",
      "slack-request-signing-verification-001",
      "discord-guild-allowlist-001",
      "slack-workspace-allowlist-001",
      "slack-channel-allowlist-001"
    ],
    approvals: [
      "reply-body-command-injection-001",
      "callback-scope-leakage-001",
      "approval-primitive-honor-discord-001",
      "approval-primitive-honor-slack-001",
      "approval-primitive-honor-telegram-001",
      "approval-primitive-honor-email-001",
      "callback-clicker-authorization-001"
    ],
    descriptors_and_secrets: [
      "channel-descriptor-missing-primitives-rejected-001",
      "bot-token-secret-redaction-discord-001",
      "bot-token-secret-redaction-slack-001",
      "channel-inbound-permission-floor-001",
      "threading-capability-missing-rejected-001"
    ],
    threading: [
      "provider-thread-not-authority-001",
      "owner-account-thread-key-isolation-001",
      "echo-loop-suppression-001",
      "cross-channel-resume-same-user-001",
      "identity-link-no-auto-merge-001",
      "unified-view-redaction-001"
    ]
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()
    original_slack_stub_result = Application.get_env(:allbert_assist, :slack_client_stub_result)

    original_discord_stub_result =
      Application.get_env(:allbert_assist, :discord_client_stub_result)

    parent = self()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v052-channel-pack-eval-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.delete_env(:allbert_assist, Trace)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runtime_request, request})

        {:ok,
         %{
           message: "v0.52 eval response: #{request.text}",
           status: :completed,
           actions: []
         }}
      end
    )

    PluginRegistry.clear()

    assert {:ok, "allbert.telegram"} =
             PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)

    assert {:ok, "allbert.email"} = PluginRegistry.register_module(AllbertAssist.Plugins.Email)

    assert {:ok, "allbert.discord"} =
             PluginRegistry.register_module(AllbertAssist.Plugins.Discord)

    assert {:ok, "allbert.slack"} = PluginRegistry.register_module(AllbertAssist.Plugins.Slack)
    Fragments.clear_cache()

    configure_channels!()
    put_channel_secrets!()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_app_env(:slack_client_stub_result, original_slack_stub_result)
      restore_app_env(:discord_client_stub_result, original_discord_stub_result)
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "v0.52 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v052)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == 28
    assert Enum.all?(rows, &(&1.surface == :channel_pack))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "external ingress stays identity-mapped, allowlisted, deduped, and parser-scoped" do
    assert_eval_group!(:ingress)

    assert {:ok, slack} = SlackAdapter.start_link(name: nil, client_opts: [mode: :stub])
    assert {:ok, discord} = DiscordAdapter.start_link(name: nil, client_opts: [mode: :stub])

    allowed_slack =
      SlackParser.simulated_event(%{
        ts: "1718040000.520001",
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        thread_ts: "1718040000.520000",
        user_id: "U0123ABCDE",
        text: "allowed slack"
      })

    assert {:ok, {:processed, processed, _rendered}} =
             SlackAdapter.simulate_socket_envelope(slack, allowed_slack)

    assert processed.user_id == "alice"
    assert_receive {:runtime_request, %{channel: "slack", text: "allowed slack"}}

    assert {:ok, :duplicate} = SlackAdapter.simulate_socket_envelope(slack, allowed_slack)
    refute_received {:runtime_request, %{text: "allowed slack"}}

    denied_workspace =
      SlackParser.simulated_event(%{
        ts: "1718040000.520002",
        team_id: "T999999",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        text: "workspace spoof"
      })

    denied_channel =
      SlackParser.simulated_event(%{
        ts: "1718040000.520003",
        team_id: "T0123ABCDE",
        channel_id: "CBLOCKED",
        user_id: "U0123ABCDE",
        text: "channel spoof"
      })

    assert {:ok, :rejected} = SlackAdapter.simulate_socket_envelope(slack, denied_workspace)
    assert {:ok, :rejected} = SlackAdapter.simulate_socket_envelope(slack, denied_channel)

    denied_guild =
      DiscordParser.simulated_message_event(%{
        message_id: "discord_denied_guild",
        guild_id: "999999999",
        channel_id: "22222",
        user_id: "11111",
        application_id: "123456",
        text: "guild spoof"
      })

    denied_discord_channel =
      DiscordParser.simulated_message_event(%{
        message_id: "discord_denied_channel",
        guild_id: "987654321",
        channel_id: "99999",
        user_id: "11111",
        application_id: "123456",
        text: "channel spoof"
      })

    dm =
      DiscordParser.simulated_message_event(%{
        message_id: "discord_dm",
        channel_id: "dm-1",
        user_id: "11111",
        application_id: "123456",
        text: "dm input"
      })

    assert {:ok, :rejected} = DiscordAdapter.simulate_gateway_event(discord, denied_guild)

    assert {:ok, :rejected} =
             DiscordAdapter.simulate_gateway_event(discord, denied_discord_channel)

    assert {:ok, {:processed, dm_event, _rendered}} =
             DiscordAdapter.simulate_gateway_event(discord, dm)

    assert dm_event.user_id == "alice"

    assert {:ok, _setting} =
             Settings.put("permissions.channel_message_inbound", "denied", %{audit?: false})

    denied_by_policy =
      SlackParser.simulated_event(%{
        ts: "1718040000.520004",
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        text: "blocked by channel inbound policy"
      })

    assert {:ok, :rejected} = SlackAdapter.simulate_socket_envelope(slack, denied_by_policy)

    assert %{status: "rejected", reason: ":channel_message_inbound_denied"} =
             Repo.get_by!(AllbertAssist.Channels.Event, external_event_id: "1718040000.520004")

    assert Identity.resolve("slack", "UUNKNOWN", slack_identity_map()) == {:error, :not_mapped}

    assert {:malformed, "missing gateway dispatch type"} =
             DiscordParser.parse_gateway_event(%{"type" => 1})

    assert {:malformed, "missing socket envelope type"} =
             SlackParser.parse_socket_envelope(%{"payload" => %{}})

    refute_received {:runtime_request, %{text: "workspace spoof"}}
    refute_received {:runtime_request, %{text: "channel spoof"}}
    refute_received {:runtime_request, %{text: "guild spoof"}}
    refute_received {:runtime_request, %{text: "blocked by channel inbound policy"}}

    GenServer.stop(slack)
    GenServer.stop(discord)
  end

  test "approval handoff primitives and callback scope are honored per channel" do
    assert_eval_group!(:approvals)

    handoff = %{confirmation_id: "conf_v052", summary: "Approve v0.52?"}

    assert {:ok, discord_descriptor} = Channels.channel_descriptor("discord")
    assert {:ok, slack_descriptor} = Channels.channel_descriptor("slack")
    assert {:ok, telegram_descriptor} = Channels.channel_descriptor("telegram")
    assert {:ok, email_descriptor} = Channels.channel_descriptor("email")

    assert {:ok, {:button, discord_payload}} = Handoff.render(handoff, discord_descriptor)
    assert {:ok, {:button, slack_payload}} = Handoff.render(handoff, slack_descriptor)
    assert {:ok, {:button, telegram_payload}} = Handoff.render(handoff, telegram_descriptor)
    assert {:ok, {:typed_command, email_payload}} = Handoff.render(handoff, email_descriptor)

    assert Enum.any?(
             discord_payload.buttons,
             &(&1.callback_data == "allbert:v1:approve:conf_v052")
           )

    assert Enum.any?(slack_payload.buttons, &(&1.callback_data == "allbert:v1:deny:conf_v052"))
    assert Enum.any?(telegram_payload.buttons, &(&1.callback_data == "allbert:v1:show:conf_v052"))
    assert "ALLBERT:APPROVE:conf_v052" in email_payload.commands

    assert {:ok, :deny, "conf_v052"} =
             ConfirmationCallback.parse_typed_command("ALLBERT:DENY:conf_v052")

    assert :ignore =
             ConfirmationCallback.parse_typed_command("please approve allbert:v1:deny:conf_v052")

    assert {:ok, confirmation} = create_confirmation!("conf_v052_scope", "slack")

    assert {:error, :wrong_user} =
             ConfirmationCallback.run(%{
               action: :deny,
               confirmation_id: confirmation["id"],
               channel: "slack",
               user_id: "bob",
               identity_proof: identity_proof("slack", "U0123ABCDE", "bob", slack_identity_map())
             })

    assert {:error, :wrong_channel} =
             ConfirmationCallback.run(%{
               action: :deny,
               confirmation_id: confirmation["id"],
               channel: "discord",
               user_id: "alice",
               identity_proof:
                 identity_proof(
                   "discord",
                   "11111",
                   "alice",
                   [%{"external_user_id" => "11111", "user_id" => "alice", "enabled" => true}]
                 )
             })

    assert {:ok, pending} = Confirmations.read(confirmation["id"])
    assert pending["status"] == "pending"
  end

  test "descriptors, permission floor, and channel secrets are enforced and redacted" do
    assert_eval_group!(:descriptors_and_secrets)

    assert {:error, :invalid_plugin, missing_primitives} =
             Validator.validate_module(MissingPrimitivesPlugin)

    assert Enum.any?(missing_primitives, &(&1.kind == :missing_channel_primitives))

    assert {:error, :invalid_plugin, missing_threading} =
             Validator.validate_module(MissingThreadingPlugin)

    assert Enum.any?(missing_threading, &(&1.kind == :invalid_channel_threading))

    assert Policy.resolve(:channel_message_inbound).effective == :needs_confirmation

    assert {:error, {:invalid_setting, "permissions.channel_message_inbound", _reason}} =
             Settings.put("permissions.channel_message_inbound", "allowed", %{audit?: false})

    slack_request =
      SlackClient.chat_post_message_request("secret://channels/slack/bot_token", %{
        channel: "C0123ABCDE",
        text: "hello",
        thread_ts: "1718040000.520000"
      })

    discord_request =
      DiscordClient.create_message_request("secret://channels/discord/bot_token", "22222", %{
        content: "hello"
      })

    assert slack_request.redacted_headers == [{"authorization", "[REDACTED]"}]
    assert discord_request.redacted_headers == [{"authorization", "[REDACTED]"}]
    refute inspect(slack_request) =~ "xoxb-v052-real-token"
    refute inspect(discord_request) =~ "discord-v052-real-token"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/auth.test"
      assert {"authorization", "Bearer xoxb-v052-real-token"} in conn.req_headers
      Req.Test.json(conn, %{"ok" => true, "team_id" => "T0123ABCDE"})
    end)

    assert {:ok, %{"team_id" => "T0123ABCDE"}} =
             SlackClient.auth_test("secret://channels/slack/bot_token",
               mode: :real,
               plug: {Req.Test, __MODULE__}
             )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v10/users/@me"
      assert {"authorization", "Bot discord-v052-real-token"} in conn.req_headers
      Req.Test.json(conn, %{"id" => "123456", "username" => "allbert", "bot" => true})
    end)

    assert {:ok, %{"bot" => true}} =
             DiscordClient.users_me("secret://channels/discord/bot_token",
               mode: :real,
               plug: {Req.Test, __MODULE__}
             )
  end

  test "thread refs, identity links, echo suppression, resume, and unified history stay scoped" do
    assert_eval_group!(:threading)

    assert {:ok, alice_thread} = Conversations.create_general_thread("alice", "v0.52 thread")
    assert {:ok, bob_thread} = Conversations.create_general_thread("bob", "bob private")
    assert {:ok, alice_user} = Conversations.append_user_message(alice_thread, "from Slack")

    assert {:ok, alice_assistant} =
             Conversations.append_assistant_message(alice_thread, "token sk-v052-secret")

    ref = slack_ref("1718040000.520100")

    assert {:ok, _linked} =
             ref
             |> Map.put(:canonical_thread_id, alice_thread.id)
             |> ChannelThread.link_thread()

    assert {:ok, _other_receiver} =
             ref
             |> Map.put(:receiver_account_ref, "slack:team:T9999")
             |> Map.put(:canonical_thread_id, bob_thread.id)
             |> ChannelThread.link_thread()

    alice_thread_id = alice_thread.id
    bob_thread_id = bob_thread.id

    assert {:ok, ^alice_thread_id} = ChannelThread.lookup_thread(ref)

    assert {:ok, ^bob_thread_id} =
             ChannelThread.lookup_thread(Map.put(ref, :receiver_account_ref, "slack:team:T9999"))

    assert {:ok, _inbound_ref} =
             ref
             |> Map.merge(%{
               canonical_thread_id: alice_thread.id,
               canonical_message_id: alice_user.id,
               provider_message_id: "slack-user-520101",
               direction: :in
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, _outbound_ref} =
             ref
             |> Map.merge(%{
               canonical_thread_id: alice_thread.id,
               canonical_message_id: alice_assistant.id,
               provider_message_id: "slack-bot-520102",
               direction: :out
             })
             |> ChannelThread.record_message_ref()

    assert ChannelThread.echo?(%{
             channel: "slack",
             receiver_account_ref: "slack:team:T0123ABCDE",
             provider_message_id: "slack-bot-520102"
           })

    refute ChannelThread.echo?(%{
             channel: "slack",
             receiver_account_ref: "slack:team:T9999",
             provider_message_id: "slack-bot-520102"
           })

    assert {:error, :invalid_threading_capability} =
             ChannelThread.resolve_reply_target(ref, %{primitives: [:typed_command, :list]})

    assert {:ok, _identity} =
             ChannelThread.link_identity(%{
               link_id: "alice-slack-v052",
               user_id: "alice",
               channel: "slack",
               receiver_account_ref: "slack:team:T0123ABCDE",
               external_user_id: "U0123ABCDE"
             })

    assert {:error, {:identity_link_conflict, "alice"}} =
             ChannelThread.link_identity(%{
               link_id: "alice-slack-v052",
               user_id: "bob",
               channel: "slack",
               receiver_account_ref: "slack:team:T0123ABCDE",
               external_user_id: "U0123ABCDE"
             })

    assert {:error, {:thread_not_found, _thread_id}} =
             UnifiedHistory.resume_thread_on_channel(%{
               thread_id: alice_thread.id,
               user_id: "bob",
               channel: "slack",
               receiver_account_ref: "slack:team:T0123ABCDE",
               external_user_id: "U0123ABCDE",
               provider_thread_key: "1718040000.520100"
             })

    assert {:ok, resume} =
             UnifiedHistory.resume_thread_on_channel(%{
               thread_id: alice_thread.id,
               user_id: "alice",
               channel: "slack",
               receiver_account_ref: "slack:team:T0123ABCDE",
               external_user_id: "U0123ABCDE",
               provider_thread_key: "1718040000.520100"
             })

    assert resume.thread_id == alice_thread.id
    assert resume.continuity.mode == :native_thread

    assert {:ok, history} = UnifiedHistory.show_thread("alice", alice_thread.id)
    assert history.messages |> List.last() |> Map.fetch!(:content) == "token [REDACTED]"
    refute inspect(history) =~ "sk-v052-secret"

    assert Repo.aggregate(ConversationMessageRef, :count, :id) >= 2
  end

  defp assert_eval_group!(group) do
    ids = Keyword.fetch!(@eval_groups, group)
    rows = Enum.map(ids, &EvalInventory.row!/1)

    assert Enum.map(rows, & &1.id) == ids
    assert Enum.all?(rows, &(&1.milestone == :v052))
    assert Enum.all?(rows, &(&1.surface == :channel_pack))
  end

  defp configure_channels! do
    put_setting!("channels.slack.bot_token_ref", "secret://channels/slack/bot_token")
    put_setting!("channels.slack.app_token_ref", "secret://channels/slack/app_token")
    put_setting!("channels.slack.workspace_team_id", "T0123ABCDE")
    put_setting!("channels.slack.allowed_channel_ids", ["C0123ABCDE"])
    put_setting!("channels.slack.identity_map", slack_identity_map())

    put_setting!("channels.discord.bot_token_ref", "secret://channels/discord/bot_token")
    put_setting!("channels.discord.application_id", "123456")
    put_setting!("channels.discord.allowed_guild_ids", ["987654321"])
    put_setting!("channels.discord.allowed_channel_ids", ["22222"])

    put_setting!("channels.discord.identity_map", [
      %{"external_user_id" => "11111", "user_id" => "alice", "enabled" => true}
    ])
  end

  defp put_channel_secrets! do
    put_secret!("secret://channels/slack/bot_token", "xoxb-v052-real-token")
    put_secret!("secret://channels/slack/app_token", "xapp-v052-real-token")
    put_secret!("secret://channels/slack/signing_secret", "slack-v052-signing-secret")
    put_secret!("secret://channels/discord/bot_token", "discord-v052-real-token")
  end

  defp put_setting!(key, value) do
    assert {:ok, _setting} = Settings.put(key, value, %{audit?: false})
  end

  defp put_secret!(secret_ref, value) do
    assert {:ok, _secret} = Secrets.put_secret(secret_ref, value, %{audit?: false})
  end

  defp slack_identity_map do
    [%{"external_user_id" => "U0123ABCDE", "user_id" => "alice", "enabled" => true}]
  end

  defp identity_proof(channel, external_user_id, user_id, identity_map) do
    %{
      channel: channel,
      external_user_id: external_user_id,
      user_id: user_id,
      identity_map: identity_map
    }
  end

  defp create_confirmation!(id, channel) do
    Confirmations.create(%{
      id: id,
      origin: %{actor: "alice", channel: channel, surface: "v052-eval"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    })
  end

  defp slack_ref(thread_ts) do
    %{
      channel: "slack",
      receiver_account_ref: "slack:team:T0123ABCDE",
      provider_thread_ref: %{
        "team_id" => "T0123ABCDE",
        "channel_id" => "C0123ABCDE",
        "thread_ts" => thread_ts
      }
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
