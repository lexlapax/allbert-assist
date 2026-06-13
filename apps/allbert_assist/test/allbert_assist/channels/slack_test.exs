defmodule AllbertAssist.Channels.SlackTest do
  use AllbertAssist.DataCase, async: false

  import Ecto.Query

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Slack.Adapter
  alias AllbertAssist.Channels.Slack.Client
  alias AllbertAssist.Channels.Slack.Client.SocketModePort
  alias AllbertAssist.Channels.Slack.Parser
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Slack, as: SlackPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace
  alias AllbertSlack.Settings.Fragment, as: SlackSettingsFragment

  defmodule FakeWebSocket do
    use GenServer

    def start_link(url, callback, state, opts) do
      if is_pid(state.owner) do
        send(state.owner, {:fake_websocket_started, url, callback, state, opts})
      end

      GenServer.start_link(__MODULE__, state)
    end

    @impl true
    def init(state), do: {:ok, state}
  end

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()
    original_stub_result = Application.get_env(:allbert_assist, :slack_client_stub_result)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-slack-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    assert {:ok, "allbert.slack"} = PluginRegistry.register_module(SlackPlugin)
    Fragments.clear_cache()

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})
        {:ok, %{message: "Slack response: #{request.text}", status: :completed}}
      end
    )

    configure_slack()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_app_env(:slack_client_stub_result, original_stub_result)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "plugin descriptor declares the v0.52 Slack channel contract" do
    assert [descriptor] = SlackPlugin.channels()

    assert descriptor.channel_id == "slack"
    assert descriptor.provider == "slack_socket_mode"
    assert descriptor.primitives == [:button, :typed_command, :list]
    assert descriptor.threading == :native_threads
    assert descriptor.settings_prefix == "channels.slack"
    assert descriptor.identity_map_key == "channels.slack.identity_map"
    assert descriptor.session_strategy == {:slack_native_thread, prefix: "ch_sl_"}

    assert {:ok, descriptor} = Channels.channel_descriptor("slack")
    assert descriptor.threading == :native_threads
  end

  test "settings fragment reports required fields when Slack is enabled" do
    diagnostics =
      SlackSettingsFragment.required_when_enabled(%{
        "enabled" => true,
        "bot_token_ref" => "",
        "app_token_ref" => "",
        "workspace_team_id" => "",
        "allowed_channel_ids" => []
      })

    assert :missing_bot_token_ref in diagnostics
    assert :missing_app_token_ref in diagnostics
    assert :missing_workspace_team_id in diagnostics
    assert :missing_allowed_channel_ids in diagnostics
  end

  test "client exposes deterministic stubs and redacted request shapes" do
    assert {:ok, auth} = Client.auth_test("secret://channels/slack/bot_token")
    assert auth["ok"]
    assert auth["team_id"] == "T0123ABCDE"

    request =
      Client.chat_post_message_request("secret://channels/slack/bot_token", %{
        channel: "C0123ABCDE",
        text: "hello",
        thread_ts: "1718040000.000100"
      })

    assert request.method == :post
    assert request.path == "/chat.postMessage"
    assert request.redacted_headers == [{"authorization", "[REDACTED]"}]
    refute inspect(request.redacted_headers) =~ "Bearer "

    socket_request = Client.apps_connections_open_request("secret://channels/slack/app_token")

    assert socket_request.method == :post
    assert socket_request.path == "/apps.connections.open"
    assert socket_request.redacted_headers == [{"authorization", "[REDACTED]"}]

    assert {:ok, %{"ok" => true, "url" => socket_url}} =
             Client.apps_connections_open("secret://channels/slack/app_token")

    assert socket_url =~ "wss://wss-primary.slack.com"

    Application.put_env(:allbert_assist, :slack_client_stub_result, :unauthorized)

    assert {:error, {:slack_error, "invalid_auth"}} =
             Client.auth_test("secret://channels/slack/bot_token")
  end

  test "parser normalizes Socket Mode message and interactive envelopes" do
    envelope =
      Parser.simulated_event(%{
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        thread_ts: "1718040000.000100",
        user_id: "U0123ABCDE",
        text: "hello"
      })

    assert {:message, fields} = Parser.parse_socket_envelope(envelope)
    assert fields.team_id == "T0123ABCDE"
    assert fields.channel_id == "C0123ABCDE"
    assert fields.thread_ts == "1718040000.000100"
    assert fields.receiver_account_ref == "slack:team:T0123ABCDE"
    assert fields.channel_thread_ref.channel == "slack"
    assert fields.channel_thread_ref.provider_thread_ref.thread_ts == "1718040000.000100"

    interactive =
      Parser.simulated_interactive(%{
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        action_id: "allbert:v1:deny:conf_123"
      })

    assert {:interactive, callback} = Parser.parse_socket_envelope(interactive)
    assert callback.verb == :deny
    assert callback.confirmation_id == "conf_123"
  end

  test "SocketModePort stub forwards envelopes and acks by envelope_id" do
    assert {:ok, port} = SocketModePort.Stub.start_link(owner: self())
    assert :ok = SocketModePort.Stub.push(port, %{"type" => "hello", "envelope_id" => "env_1"})
    assert_receive {:slack_socket_envelope, %{"type" => "hello"}}

    assert :ok = SocketModePort.Stub.ack(port, "env_1", nil)
    assert_receive {:slack_socket_ack, %{"envelope_id" => "env_1"}}
  end

  test "SocketModePort real starts a WebSocket client and acks envelopes" do
    assert {:ok, port} =
             SocketModePort.Real.start_link(
               owner: self(),
               app_token_ref: "secret://channels/slack/app_token",
               socket_mode_url: "wss://wss-primary.slack.com/link/?ticket=fixture",
               websocket_module: FakeWebSocket
             )

    assert is_pid(port)

    assert_receive {:fake_websocket_started, url, SocketModePort.Real, start_state,
                    websocket_opts}

    assert url =~ "wss://wss-primary.slack.com/link/"
    assert start_state.owner == self()
    assert Keyword.get(websocket_opts, :handle_initial_conn_failure)

    state = %{owner: self(), reconnect_max_backoff_ms: 1_000}
    envelope = %{"type" => "events_api", "envelope_id" => "env_real_1", "payload" => %{}}

    assert {:reply, {:text, ack_json}, ^state} =
             SocketModePort.Real.handle_frame({:text, Jason.encode!(envelope)}, state)

    assert Jason.decode!(ack_json) == %{"envelope_id" => "env_real_1"}
    refute_received {:slack_socket_envelope, ^envelope}
    assert_receive {:slack_socket_dispatch_after_ack, ^envelope}

    assert {:ok, ^state} =
             SocketModePort.Real.handle_info({:slack_socket_dispatch_after_ack, envelope}, state)

    assert_receive {:slack_socket_envelope, ^envelope}

    hello = %{"type" => "hello"}
    assert {:ok, ^state} = SocketModePort.Real.handle_frame({:text, Jason.encode!(hello)}, state)
    assert_receive {:slack_socket_envelope, ^hello}
  end

  test "adapter handles simulated inbound messages through runtime and thread refs" do
    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    event =
      Parser.simulated_event(%{
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        thread_ts: "1718040000.000100",
        user_id: "U0123ABCDE",
        text: "hello allbert"
      })

    assert {:ok, {:processed, processed_event, [rendered]}} =
             Adapter.simulate_socket_envelope(adapter, event)

    GenServer.stop(adapter)

    assert processed_event.status == "processed"
    assert processed_event.user_id == "alice"
    assert String.starts_with?(processed_event.session_id, "ch_sl_")
    assert rendered.text == "Slack response: hello allbert"

    assert_received {:runtime_request, request}
    assert request.channel == "slack"
    assert request.text == "hello allbert"
    assert request.metadata.inbound_trust.decision == :needs_confirmation
    assert request.channel_thread_ref.receiver_account_ref == "slack:team:T0123ABCDE"

    refs =
      ConversationMessageRef
      |> where([ref], ref.channel == "slack")
      |> order_by([ref], asc: ref.direction)
      |> Repo.all()

    assert Enum.any?(refs, &(&1.direction == "in"))
    assert Enum.any?(refs, &(&1.direction == "out"))
  end

  test "adapter rejects unmapped users and non-allowlisted workspaces or channels before runtime" do
    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    unmapped =
      Parser.simulated_event(%{
        ts: "1718040000.000301",
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "UUNKNOWN",
        text: "from stranger"
      })

    denied_workspace =
      Parser.simulated_event(%{
        ts: "1718040000.000302",
        team_id: "T9999",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        text: "from denied workspace"
      })

    denied_channel =
      Parser.simulated_event(%{
        ts: "1718040000.000303",
        team_id: "T0123ABCDE",
        channel_id: "C9999",
        user_id: "U0123ABCDE",
        text: "from denied channel"
      })

    assert {:ok, :rejected} = Adapter.simulate_socket_envelope(adapter, unmapped)
    assert {:ok, :rejected} = Adapter.simulate_socket_envelope(adapter, denied_workspace)
    assert {:ok, :rejected} = Adapter.simulate_socket_envelope(adapter, denied_channel)

    GenServer.stop(adapter)

    assert %{status: "rejected", reason: ":not_mapped"} =
             Repo.get_by!(AllbertAssist.Channels.Event, external_event_id: "1718040000.000301")

    assert %{status: "rejected", reason: ":team_not_allowed"} =
             Repo.get_by!(AllbertAssist.Channels.Event, external_event_id: "1718040000.000302")

    assert %{status: "rejected", reason: ":channel_not_allowed"} =
             Repo.get_by!(AllbertAssist.Channels.Event, external_event_id: "1718040000.000303")

    refute_received {:runtime_request, _request}
  end

  test "adapter rejects channel messages when inbound trust is denied" do
    assert {:ok, _setting} =
             Settings.put("permissions.channel_message_inbound", "denied", %{audit?: false})

    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    event =
      Parser.simulated_event(%{
        ts: "1718040000.000311",
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        text: "blocked by inbound trust"
      })

    assert {:ok, :rejected} = Adapter.simulate_socket_envelope(adapter, event)

    GenServer.stop(adapter)

    assert %{status: "rejected", reason: ":channel_message_inbound_denied"} =
             Repo.get_by!(AllbertAssist.Channels.Event, external_event_id: "1718040000.000311")

    refute_received {:runtime_request, _request}
  end

  test "adapter preserves Slack thread_ts without treating it as canonical thread authority" do
    assert {:ok, adapter} =
             Adapter.start_link(name: nil, client_opts: [mode: :stub, capture_to: self()])

    event =
      Parser.simulated_event(%{
        ts: "1718040000.000401",
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        thread_ts: "1718040000.000100",
        user_id: "U0123ABCDE",
        text: "thread placement"
      })

    assert {:ok, {:processed, processed_event, _rendered}} =
             Adapter.simulate_socket_envelope(adapter, event)

    assert_receive {:slack_chat_post_message, payload}
    assert payload.channel == "C0123ABCDE"
    assert payload.thread_ts == "1718040000.000100"
    assert processed_event.thread_id != "1718040000.000100"

    assert_received {:runtime_request, request}
    assert request.channel_thread_ref.provider_thread_ref["thread_ts"] == "1718040000.000100"
    assert request.channel_thread_ref.receiver_account_ref == "slack:team:T0123ABCDE"

    GenServer.stop(adapter)
  end

  test "confirmation callbacks resolve through registered actions with resolver metadata" do
    assert {:ok, confirmation} = create_confirmation!("conf_slack_deny", "slack")

    assert {:ok, adapter} =
             Adapter.start_link(name: nil, client_opts: [mode: :stub, capture_to: self()])

    interactive =
      Parser.simulated_interactive(%{
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        action_id: "allbert:v1:deny:#{confirmation["id"]}"
      })

    assert {:ok, {:processed, event, [rendered]}} =
             Adapter.simulate_socket_envelope(adapter, interactive)

    assert_receive {:slack_chat_post_message, payload}
    assert payload.text =~ "denied"
    assert payload.channel == "C0123ABCDE"
    assert rendered.text =~ "denied"

    GenServer.stop(adapter)

    assert event.direction == "callback"
    assert event.status == "processed"
    assert event.user_id == "alice"

    assert {:ok, resolved} = Confirmations.read(confirmation["id"])
    assert resolved["status"] == "denied"
    assert resolved["operator_resolution"]["resolver_actor"] == "alice"
    assert resolved["operator_resolution"]["resolver_channel"] == "slack"
    assert resolved["operator_resolution"]["resolver_metadata"]["callback_data"] =~ "deny"
  end

  test "Slack callbacks cannot resolve Discord-origin confirmations" do
    assert {:ok, confirmation} = create_confirmation!("conf_discord_origin", "discord")

    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    interactive =
      Parser.simulated_interactive(%{
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        action_id: "allbert:v1:deny:#{confirmation["id"]}"
      })

    external_event_id = interactive["envelope_id"]

    assert {:ok, :rejected} = Adapter.simulate_socket_envelope(adapter, interactive)

    GenServer.stop(adapter)

    assert %{status: "rejected", reason: ":wrong_channel"} =
             Repo.get_by!(AllbertAssist.Channels.Event, external_event_id: external_event_id)

    assert {:ok, pending} = Confirmations.read(confirmation["id"])
    assert pending["status"] == "pending"
  end

  test "typed confirmation commands resolve without runtime submission" do
    assert {:ok, confirmation} = create_confirmation!("conf_slack_typed", "slack")

    assert {:ok, adapter} =
             Adapter.start_link(name: nil, client_opts: [mode: :stub, capture_to: self()])

    command =
      Parser.simulated_event(%{
        ts: "1718040000.000501",
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        text: "ALLBERT:DENY:#{confirmation["id"]}"
      })

    assert {:ok, {:processed, event, [rendered]}} =
             Adapter.simulate_socket_envelope(adapter, command)

    assert_receive {:slack_chat_post_message, payload}
    assert payload.text =~ "denied"
    assert rendered.text =~ "denied"
    refute_received {:runtime_request, %{text: "ALLBERT:DENY:" <> _rest}}

    GenServer.stop(adapter)

    assert event.status == "processed"
    assert {:ok, resolved} = Confirmations.read(confirmation["id"])
    assert resolved["status"] == "denied"
  end

  test "different Slack thread roots produce different sessions" do
    assert {:ok, first} = Adapter.start_link(name: nil, client_opts: [mode: :stub])
    assert {:ok, second} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    first_event =
      Parser.simulated_event(%{
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        thread_ts: "1718040000.000100",
        user_id: "U0123ABCDE",
        text: "first"
      })

    second_event =
      Parser.simulated_event(%{
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        thread_ts: "1718040000.000200",
        user_id: "U0123ABCDE",
        text: "second"
      })

    assert {:ok, {:processed, first_processed, _rendered}} =
             Adapter.simulate_socket_envelope(first, first_event)

    assert {:ok, {:processed, second_processed, _rendered}} =
             Adapter.simulate_socket_envelope(second, second_event)

    GenServer.stop(first)
    GenServer.stop(second)

    assert first_processed.session_id != second_processed.session_id
  end

  test "parser surfaces provider-fidelity signals (event_type, channel_type, subtype, bot_id, is_dm?)" do
    dm =
      Parser.simulated_event(%{
        type: "message",
        channel_type: "im",
        team_id: "T0123ABCDE",
        channel_id: "D0123ABCDE",
        user_id: "U0123ABCDE",
        text: "dm hello"
      })

    assert {:message, dm_fields} = Parser.parse_socket_envelope(dm)
    assert dm_fields.event_type == "message"
    assert dm_fields.channel_type == "im"
    assert dm_fields.is_dm? == true
    assert dm_fields.subtype == nil
    assert dm_fields.bot_id == nil

    bot =
      Parser.simulated_event(%{
        type: "message",
        subtype: "bot_message",
        bot_id: "B0999",
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        text: "echo"
      })

    assert {:message, bot_fields} = Parser.parse_socket_envelope(bot)
    assert bot_fields.subtype == "bot_message"
    assert bot_fields.bot_id == "B0999"
    assert bot_fields.is_dm? == false

    mention =
      Parser.simulated_event(%{
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        text: "hey"
      })

    assert {:message, mention_fields} = Parser.parse_socket_envelope(mention)
    assert mention_fields.event_type == "app_mention"
    assert mention_fields.is_dm? == false
  end

  test "adapter ignores provider echoes (bot_id and edit/delete subtypes) without persisting an event" do
    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    bot_id_event =
      Parser.simulated_event(%{
        ts: "1718040000.000401",
        type: "message",
        bot_id: "B0999",
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        text: "i am a bot"
      })

    assert {:ok, :ignored} = Adapter.simulate_socket_envelope(adapter, bot_id_event)

    ["bot_message", "message_changed", "message_deleted"]
    |> Enum.with_index()
    |> Enum.each(fn {subtype, index} ->
      event =
        Parser.simulated_event(%{
          ts: "1718040000.00041#{index}",
          type: "message",
          subtype: subtype,
          team_id: "T0123ABCDE",
          channel_id: "C0123ABCDE",
          user_id: "U0123ABCDE",
          text: "edited or removed"
        })

      assert {:ok, :ignored} = Adapter.simulate_socket_envelope(adapter, event)
    end)

    GenServer.stop(adapter)

    assert Repo.aggregate(AllbertAssist.Channels.Event, :count) == 0
    refute_received {:runtime_request, _request}
  end

  test "adapter honors response_style gating (dm_only ignores channel mentions, processes DMs)" do
    assert {:ok, _setting} =
             Settings.put("channels.slack.response_style", "dm_only", %{audit?: false})

    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    mention =
      Parser.simulated_event(%{
        ts: "1718040000.000501",
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "U0123ABCDE",
        text: "hey allbert"
      })

    dm =
      Parser.simulated_event(%{
        ts: "1718040000.000502",
        type: "message",
        channel_type: "im",
        team_id: "T0123ABCDE",
        channel_id: "D0123ABCDE",
        user_id: "U0123ABCDE",
        text: "dm hey"
      })

    assert {:ok, :ignored} = Adapter.simulate_socket_envelope(adapter, mention)
    assert {:ok, {:processed, _event, _rendered}} = Adapter.simulate_socket_envelope(adapter, dm)

    GenServer.stop(adapter)
  end

  test "adapter gates DMs by the identity map rather than the channel allowlist" do
    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    mapped_dm =
      Parser.simulated_event(%{
        ts: "1718040000.000601",
        type: "message",
        channel_type: "im",
        team_id: "T0123ABCDE",
        channel_id: "D0123ABCDE",
        user_id: "U0123ABCDE",
        text: "mapped dm"
      })

    unmapped_dm =
      Parser.simulated_event(%{
        ts: "1718040000.000602",
        type: "message",
        channel_type: "im",
        team_id: "T0123ABCDE",
        channel_id: "D0123ABCDE",
        user_id: "USTRANGER",
        text: "stranger dm"
      })

    assert {:ok, {:processed, _e, _r}} = Adapter.simulate_socket_envelope(adapter, mapped_dm)
    assert {:ok, :rejected} = Adapter.simulate_socket_envelope(adapter, unmapped_dm)

    GenServer.stop(adapter)
  end

  test "adapter ignores its own posts identified by bot user id" do
    assert {:ok, _setting} = Settings.put("channels.slack.enabled", true, %{audit?: false})
    Fragments.clear_cache()

    assert {:ok, adapter} =
             Adapter.start_link(
               name: nil,
               client_opts: [mode: :stub],
               socket_mode_port: SocketModePort.Stub
             )

    own =
      Parser.simulated_event(%{
        ts: "1718040000.000701",
        team_id: "T0123ABCDE",
        channel_id: "C0123ABCDE",
        user_id: "UALLBERTBOT",
        text: "echo of my own message"
      })

    assert {:ok, :ignored} = Adapter.simulate_socket_envelope(adapter, own)

    GenServer.stop(adapter)
    refute_received {:runtime_request, _request}
  end

  test "SocketModePort reconnects on a disconnect frame without dispatching it" do
    state = %{owner: self(), reconnect_max_backoff_ms: 1_000, graceful_reconnect?: false}
    disconnect = %{"type" => "disconnect", "reason" => "refresh_requested"}

    assert {:close, closed_state} =
             SocketModePort.Real.handle_frame({:text, Jason.encode!(disconnect)}, state)

    assert closed_state.graceful_reconnect? == true
    refute_received {:slack_socket_envelope, _envelope}

    assert {:reconnect, reconnected} =
             SocketModePort.Real.handle_disconnect(
               %{attempt_number: 1, reason: :normal},
               closed_state
             )

    assert reconnected.graceful_reconnect? == false
  end

  test "adapter exposes live transport status for the provider doctor" do
    assert Adapter.status(__MODULE__.NoSuchAdapter) == :not_started

    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])
    assert Adapter.status(adapter) == :disabled

    GenServer.stop(adapter)
  end

  test "redactor masks Slack app-level (xapp-) and bot (xoxb-) token shapes" do
    redacted =
      AllbertAssist.Security.Redactor.redact(
        "connect xapp-1-A0000-secret and xoxb-1111-bottoken in one line"
      )

    refute redacted =~ "xapp-1-A0000-secret"
    refute redacted =~ "xoxb-1111-bottoken"
  end

  defp configure_slack do
    assert {:ok, _setting} =
             Settings.put("channels.slack.bot_token_ref", "secret://channels/slack/bot_token", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("channels.slack.app_token_ref", "secret://channels/slack/app_token", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("channels.slack.workspace_team_id", "T0123ABCDE", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.slack.allowed_channel_ids", ["C0123ABCDE"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.slack.identity_map",
               [%{"external_user_id" => "U0123ABCDE", "user_id" => "alice", "enabled" => true}],
               %{audit?: false}
             )

    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/slack/bot_token", "xoxb-test-token", %{
               audit?: false
             })

    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/slack/app_token", "xapp-test-token", %{
               audit?: false
             })
  end

  defp create_confirmation!(id, channel) do
    Confirmations.create(%{
      id: id,
      origin: %{actor: "alice", channel: channel, surface: "slack-test"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    })
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
