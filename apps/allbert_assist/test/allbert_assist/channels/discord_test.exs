defmodule AllbertAssist.Channels.DiscordTest do
  use AllbertAssist.DataCase, async: false

  import Ecto.Query

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Discord.Adapter
  alias AllbertAssist.Channels.Discord.Client
  alias AllbertAssist.Channels.Discord.Client.GatewayPort
  alias AllbertAssist.Channels.Discord.Parser
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Discord, as: DiscordPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace
  alias AllbertDiscord.Settings.Fragment, as: DiscordSettingsFragment

  defmodule FakeWebSocket do
    use GenServer

    def start_link(url, callback, state, opts) do
      if is_pid(state.owner) do
        send(
          state.owner,
          {:fake_websocket_started, url, callback, Map.delete(state, :token), opts}
        )
      end

      GenServer.start_link(__MODULE__, state)
    end

    @impl true
    def init(state), do: {:ok, state}
  end

  defmodule FakeGatewaySocket do
    def close({owner, ref}) when is_pid(owner) do
      send(owner, {:fake_gateway_socket_closed, ref})
      :ok
    end
  end

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()
    original_stub_result = Application.get_env(:allbert_assist, :discord_client_stub_result)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-discord-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()

    assert {:ok, "allbert.discord"} = PluginRegistry.register_module(DiscordPlugin)

    Fragments.clear_cache()

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})
        {:ok, %{message: "Discord response: #{request.text}", status: :completed}}
      end
    )

    configure_discord()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_app_env(:discord_client_stub_result, original_stub_result)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "plugin descriptor declares the v0.52 Discord channel contract" do
    assert [descriptor] = DiscordPlugin.channels()

    assert descriptor.channel_id == "discord"
    assert descriptor.provider == "discord_gateway"
    assert descriptor.primitives == [:button, :typed_command, :list]
    assert descriptor.threading == :native_threads
    assert descriptor.settings_prefix == "channels.discord"
    assert descriptor.identity_map_key == "channels.discord.identity_map"
    assert descriptor.session_strategy == {:discord_native_thread, prefix: "ch_di_"}

    assert {:ok, descriptor} = Channels.channel_descriptor("discord")
    assert descriptor.threading == :native_threads
  end

  test "settings fragment reports required fields when Discord is enabled" do
    diagnostics =
      DiscordSettingsFragment.required_when_enabled(%{
        "enabled" => true,
        "bot_token_ref" => "",
        "application_id" => "",
        "allowed_guild_ids" => []
      })

    assert :missing_bot_token_ref in diagnostics
    assert :missing_application_id in diagnostics
    assert :missing_allowed_guild_ids in diagnostics
  end

  test "client exposes deterministic stub responses and redacted request shapes" do
    assert {:ok, bot} = Client.users_me("secret://channels/discord/bot_token")
    assert bot["bot"]
    assert bot["username"] == "allbert-fixture"

    request =
      Client.create_message_request("secret://channels/discord/bot_token", "22222", %{
        content: "hello"
      })

    assert request.method == :post
    assert request.path == "/channels/22222/messages"
    assert request.redacted_headers == [{"authorization", "[REDACTED]"}]
    refute inspect(request.redacted_headers) =~ "Bot "

    gateway_request = Client.gateway_bot_request("secret://channels/discord/bot_token")

    assert gateway_request.method == :get
    assert gateway_request.path == "/gateway/bot"
    assert gateway_request.redacted_headers == [{"authorization", "[REDACTED]"}]

    callback_request =
      Client.interaction_callback_request("int_1", "interaction-token-secret", %{type: 6})

    assert callback_request.method == :post
    assert callback_request.path == "/interactions/int_1/[REDACTED]/callback"
    assert callback_request.url =~ "/interactions/int_1/[REDACTED]/callback"
    refute inspect(callback_request) =~ "interaction-token-secret"

    assert {:ok, %{"id" => "int_1", "type" => 6}} =
             Client.interaction_callback("int_1", "interaction-token-secret", %{type: 6},
               capture_to: self()
             )

    assert_receive {:discord_interaction_callback, "int_1", %{type: 6}}

    assert {:ok, %{"url" => "wss://gateway.discord.gg"}} =
             Client.gateway_bot("secret://channels/discord/bot_token")

    Application.put_env(:allbert_assist, :discord_client_stub_result, :unauthorized)

    assert {:error, {:discord_error, 401, _body}} =
             Client.users_me("secret://channels/discord/bot_token")
  end

  test "parser normalizes simulated Gateway messages and interaction callbacks" do
    event =
      Parser.simulated_message_event(%{
        guild_id: "987654321",
        channel_id: "22222",
        thread_channel_id: "33333",
        user_id: "11111",
        application_id: "123456",
        text: "hello"
      })

    assert {:message_create, fields} = Parser.parse_gateway_event(event)
    assert fields.guild_id == "987654321"
    assert fields.channel_id == "33333"
    assert fields.parent_channel_id == "22222"
    assert fields.thread_channel_id == "33333"
    assert fields.receiver_account_ref == "discord:app:123456:guild:987654321"
    assert fields.channel_thread_ref.channel == "discord"
    assert fields.channel_thread_ref.receiver_account_ref == fields.receiver_account_ref
    assert fields.channel_thread_ref.provider_thread_ref.provider_thread_root == "33333"

    interaction = %{
      "t" => "INTERACTION_CREATE",
      "d" => %{
        "id" => "int_1",
        "token" => "interaction-token-secret",
        "user" => %{"id" => "11111"},
        "data" => %{"custom_id" => "allbert:v1:approve:conf_123"}
      }
    }

    assert {:interaction_create, callback} = Parser.parse_gateway_event(interaction)
    assert callback.verb == :approve
    assert callback.confirmation_id == "conf_123"
    assert callback.interaction_token == "interaction-token-secret"
    refute callback.raw_summary =~ "interaction-token-secret"
  end

  test "GatewayPort stub forwards simulated events to the owner" do
    assert {:ok, port} = GatewayPort.Stub.start_link(owner: self())
    assert :ok = GatewayPort.Stub.push(port, %{"t" => "READY", "d" => %{"session_id" => "s1"}})
    assert_receive {:discord_gateway_event, %{"t" => "READY"}}
  end

  test "GatewayPort real starts a WebSocket client and handles gateway frames" do
    assert {:ok, port} =
             GatewayPort.Real.start_link(
               owner: self(),
               token_ref: "secret://channels/discord/bot_token",
               gateway_url: "wss://gateway.discord.gg",
               websocket_module: FakeWebSocket
             )

    assert is_pid(port)

    assert_receive {:fake_websocket_started, url, GatewayPort.Real, start_state, websocket_opts}
    assert url =~ "wss://gateway.discord.gg"
    assert url =~ "v=10"
    assert url =~ "encoding=json"
    assert start_state.intents > 0
    refute inspect(start_state) =~ "discord-test-token"
    assert Keyword.get(websocket_opts, :handle_initial_conn_failure)

    state = gateway_state(%{sequence: nil, session_id: nil, resume?: false})

    hello = Jason.encode!(%{"op" => 10, "d" => %{"heartbeat_interval" => 60_000}})

    assert {:reply, {:text, identify_json}, state} =
             GatewayPort.Real.handle_frame({:text, hello}, state)

    identify = Jason.decode!(identify_json)
    assert identify["op"] == 2
    assert identify["d"]["intents"] == 33_280
    assert identify["d"]["properties"]["browser"] == "allbert"

    dispatch = %{
      "op" => 0,
      "t" => "READY",
      "s" => 7,
      "d" => %{"session_id" => "gateway-session-1"}
    }

    assert {:ok, state} = GatewayPort.Real.handle_frame({:text, Jason.encode!(dispatch)}, state)
    assert state.sequence == 7
    assert state.session_id == "gateway-session-1"
    assert_receive {:discord_gateway_event, ^dispatch}

    assert {:reply, {:text, heartbeat_json}, _state} =
             GatewayPort.Real.handle_info(:heartbeat, state)

    assert Jason.decode!(heartbeat_json) == %{"op" => 1, "d" => 7}
  end

  test "GatewayPort real resumes stored gateway sessions when Discord permits resume" do
    state = gateway_state(%{sequence: 7, session_id: "gateway-session-1", resume?: true})

    hello = Jason.encode!(%{"op" => 10, "d" => %{"heartbeat_interval" => 60_000}})

    assert {:reply, {:text, resume_json}, resumed_state} =
             GatewayPort.Real.handle_frame({:text, hello}, state)

    assert Jason.decode!(resume_json) == %{
             "op" => 6,
             "d" => %{
               "token" => "discord-test-token",
               "session_id" => "gateway-session-1",
               "seq" => 7
             }
           }

    refute resumed_state.resume?

    assert {:ok, reconnect_state} =
             GatewayPort.Real.handle_frame({:text, Jason.encode!(%{"op" => 7})}, resumed_state)

    assert reconnect_state.resume?

    assert {:ok, resumable_state} =
             GatewayPort.Real.handle_frame(
               {:text, Jason.encode!(%{"op" => 9, "d" => true})},
               resumed_state
             )

    assert resumable_state.resume?
    assert resumable_state.session_id == "gateway-session-1"
    assert resumable_state.sequence == 7

    assert {:ok, identify_state} =
             GatewayPort.Real.handle_frame(
               {:text, Jason.encode!(%{"op" => 9, "d" => false})},
               resumed_state
             )

    refute identify_state.resume?
    assert identify_state.session_id == nil
    assert identify_state.sequence == nil

    assert {:reply, {:text, identify_json}, _state} =
             GatewayPort.Real.handle_frame({:text, hello}, identify_state)

    assert Jason.decode!(identify_json)["op"] == 2
  end

  test "GatewayPort real forces WebSockex disconnect handling for reconnect opcodes" do
    reconnect_ref = make_ref()
    reconnect_socket = {self(), reconnect_ref}

    reconnect_state =
      gateway_state(%{
        sequence: 7,
        session_id: "gateway-session-1",
        resume?: false,
        conn: fake_gateway_conn(reconnect_socket)
      })

    assert {:ok, reconnect_state} =
             GatewayPort.Real.handle_frame(
               {:text, Jason.encode!(%{"op" => 7})},
               reconnect_state
             )

    assert reconnect_state.resume?
    assert reconnect_state.conn.socket == nil
    assert_receive {:fake_gateway_socket_closed, ^reconnect_ref}
    assert_receive {:tcp_closed, ^reconnect_socket}

    resumable_ref = make_ref()
    resumable_socket = {self(), resumable_ref}

    resumable_state =
      gateway_state(%{
        sequence: 7,
        session_id: "gateway-session-1",
        resume?: false,
        conn: fake_gateway_conn(resumable_socket)
      })

    assert {:ok, resumable_state} =
             GatewayPort.Real.handle_frame(
               {:text, Jason.encode!(%{"op" => 9, "d" => true})},
               resumable_state
             )

    assert resumable_state.resume?
    assert resumable_state.session_id == "gateway-session-1"
    assert resumable_state.sequence == 7
    assert resumable_state.conn.socket == nil
    assert_receive {:fake_gateway_socket_closed, ^resumable_ref}
    assert_receive {:tcp_closed, ^resumable_socket}

    invalid_ref = make_ref()
    invalid_socket = {self(), invalid_ref}

    invalid_state =
      gateway_state(%{
        sequence: 7,
        session_id: "gateway-session-1",
        resume?: true,
        conn: fake_gateway_conn(invalid_socket)
      })

    assert {:ok, invalid_state} =
             GatewayPort.Real.handle_frame(
               {:text, Jason.encode!(%{"op" => 9, "d" => false})},
               invalid_state
             )

    refute invalid_state.resume?
    assert invalid_state.session_id == nil
    assert invalid_state.sequence == nil
    assert invalid_state.conn.socket == nil
    assert_receive {:fake_gateway_socket_closed, ^invalid_ref}
    assert_receive {:tcp_closed, ^invalid_socket}
  end

  test "GatewayPort real includes the guilds intent and ignores unknown intent names (M8R5)" do
    assert {:ok, _port} =
             GatewayPort.Real.start_link(
               owner: self(),
               token_ref: "secret://channels/discord/bot_token",
               gateway_url: "wss://gateway.discord.gg",
               websocket_module: FakeWebSocket
             )

    assert_receive {:fake_websocket_started, _url, GatewayPort.Real, default_state, _opts}
    # guilds(1) + guild_messages(512) + direct_messages(4096) + message_content(32768)
    assert default_state.intents == 37_377

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        assert {:ok, _port} =
                 GatewayPort.Real.start_link(
                   owner: self(),
                   token_ref: "secret://channels/discord/bot_token",
                   gateway_url: "wss://gateway.discord.gg",
                   websocket_module: FakeWebSocket,
                   intents: ["guild_messages", "bogus_intent"]
                 )

        assert_receive {:fake_websocket_started, _url, GatewayPort.Real, unknown_state, _opts}

        # only the known guild_messages(512) survives; the bogus name is dropped, not silently folded
        assert unknown_state.intents == 512
      end)

    assert log =~ "unknown intent name"
    assert log =~ "bogus_intent"
  end

  test "GatewayPort real reconnects when a heartbeat is not acknowledged (M8R5)" do
    ref = make_ref()
    socket = {self(), ref}

    state =
      gateway_state(%{
        heartbeat_interval_ms: 60_000,
        last_heartbeat_acked?: true,
        conn: fake_gateway_conn(socket)
      })

    # first heartbeat sends op 1 and marks the connection as awaiting an ack
    assert {:reply, {:text, heartbeat_json}, sent_state} =
             GatewayPort.Real.handle_info(:heartbeat, state)

    assert Jason.decode!(heartbeat_json)["op"] == 1
    refute sent_state.last_heartbeat_acked?

    # an op 11 ack clears the awaiting flag
    assert {:ok, acked_state} =
             GatewayPort.Real.handle_frame({:text, Jason.encode!(%{"op" => 11})}, sent_state)

    assert acked_state.last_heartbeat_acked?

    # with no ack, the next heartbeat tick force-closes the zombied socket and reconnects (resumable)
    assert {:ok, zombie_state} = GatewayPort.Real.handle_info(:heartbeat, sent_state)
    assert zombie_state.conn.socket == nil
    assert zombie_state.resume?
    assert_receive {:fake_gateway_socket_closed, ^ref}
    assert_receive {:tcp_closed, ^socket}
  end

  test "GatewayPort real acknowledges interactions at the transport before dispatch (M8R5)" do
    state = gateway_state(%{client_opts: [mode: :stub, capture_to: self()]})

    interaction = %{
      "op" => 0,
      "t" => "INTERACTION_CREATE",
      "s" => 9,
      "d" => %{
        "id" => "gw_int_1",
        "token" => "interaction-token-secret",
        "channel_id" => "22222",
        "user" => %{"id" => "11111"},
        "data" => %{"custom_id" => "allbert:v1:approve:conf_1"}
      }
    }

    assert {:ok, acked_state} =
             GatewayPort.Real.handle_frame({:text, Jason.encode!(interaction)}, state)

    # the deferred ack (type 6) is fired by the transport, off the adapter's serial
    # mailbox, so a slow message turn can never delay it past Discord's 3s window...
    assert_receive {:discord_interaction_callback, "gw_int_1", %{type: 6}}
    # ...and the event is still forwarded to the adapter for the business callback
    assert_receive {:discord_gateway_event,
                    %{"t" => "INTERACTION_CREATE", "d" => %{"id" => "gw_int_1"}}}

    assert acked_state.sequence == 9
    refute inspect(acked_state) =~ "interaction-token-secret"
  end

  test "adapter handles simulated inbound messages through runtime and thread refs" do
    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    event =
      Parser.simulated_message_event(%{
        guild_id: "987654321",
        channel_id: "22222",
        thread_channel_id: "33333",
        user_id: "11111",
        application_id: "123456",
        text: "hello allbert"
      })

    assert {:ok, {:processed, processed_event, [rendered]}} =
             Adapter.simulate_gateway_event(adapter, event)

    GenServer.stop(adapter)

    assert processed_event.status == "processed"
    assert processed_event.user_id == "alice"
    assert String.starts_with?(processed_event.session_id, "ch_di_")
    assert rendered.content == "Discord response: hello allbert"

    assert_received {:runtime_request, request}
    assert request.channel == "discord"
    assert request.text == "hello allbert"
    assert request.metadata.inbound_trust.decision == :needs_confirmation
    assert request.channel_thread_ref.receiver_account_ref == "discord:app:123456:guild:987654321"

    refs =
      ConversationMessageRef
      |> where([ref], ref.channel == "discord")
      |> order_by([ref], asc: ref.direction)
      |> Repo.all()

    assert Enum.any?(refs, &(&1.direction == "in"))
    assert Enum.any?(refs, &(&1.direction == "out"))
  end

  test "adapter rejects unmapped users and non-allowlisted channels before runtime" do
    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    unmapped =
      Parser.simulated_message_event(%{
        message_id: "discord_unmapped",
        guild_id: "987654321",
        channel_id: "22222",
        user_id: "99999",
        application_id: "123456",
        text: "from stranger"
      })

    denied_channel =
      Parser.simulated_message_event(%{
        message_id: "discord_denied_channel",
        guild_id: "987654321",
        channel_id: "33333",
        user_id: "11111",
        application_id: "123456",
        text: "from denied channel"
      })

    assert {:ok, :rejected} = Adapter.simulate_gateway_event(adapter, unmapped)
    assert {:ok, :rejected} = Adapter.simulate_gateway_event(adapter, denied_channel)

    GenServer.stop(adapter)

    assert %{status: "rejected", reason: ":not_mapped"} =
             Repo.get_by!(AllbertAssist.Channels.Event, external_event_id: "discord_unmapped")

    assert %{status: "rejected", reason: ":channel_not_allowed"} =
             Repo.get_by!(
               AllbertAssist.Channels.Event,
               external_event_id: "discord_denied_channel"
             )

    refute_received {:runtime_request, _request}
  end

  test "adapter rejects channel messages when inbound trust is denied" do
    assert {:ok, _setting} =
             Settings.put("permissions.channel_message_inbound", "denied", %{audit?: false})

    assert {:ok, adapter} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    event =
      Parser.simulated_message_event(%{
        message_id: "discord_inbound_denied",
        guild_id: "987654321",
        channel_id: "22222",
        user_id: "11111",
        application_id: "123456",
        text: "blocked by inbound trust"
      })

    assert {:ok, :rejected} = Adapter.simulate_gateway_event(adapter, event)

    GenServer.stop(adapter)

    assert %{status: "rejected", reason: ":channel_message_inbound_denied"} =
             Repo.get_by!(AllbertAssist.Channels.Event,
               external_event_id: "discord_inbound_denied"
             )

    refute_received {:runtime_request, _request}
  end

  test "adapter preserves Discord reply placement for message references and native threads" do
    assert {:ok, adapter} =
             Adapter.start_link(name: nil, client_opts: [mode: :stub, capture_to: self()])

    reply_event =
      Parser.simulated_message_event(%{
        message_id: "discord_reply_source",
        guild_id: "987654321",
        channel_id: "22222",
        user_id: "11111",
        application_id: "123456",
        message_reference: %{
          "message_id" => "source-message",
          "channel_id" => "22222",
          "guild_id" => "987654321"
        },
        text: "reply placement"
      })

    thread_event =
      Parser.simulated_message_event(%{
        message_id: "discord_thread_source",
        guild_id: "987654321",
        channel_id: "22222",
        thread_channel_id: "thread-44444",
        user_id: "11111",
        application_id: "123456",
        text: "thread placement"
      })

    assert {:ok, {:processed, reply_processed, _rendered}} =
             Adapter.simulate_gateway_event(adapter, reply_event)

    assert_receive {:discord_create_message, "22222", reply_payload}

    assert reply_payload.message_reference == %{
             "message_id" => "source-message",
             "channel_id" => "22222",
             "guild_id" => "987654321"
           }

    assert reply_processed.thread_id != "source-message"

    assert {:ok, {:processed, thread_processed, _rendered}} =
             Adapter.simulate_gateway_event(adapter, thread_event)

    assert_receive {:discord_create_message, "thread-44444", thread_payload}
    refute Map.has_key?(thread_payload, :message_reference)
    assert thread_processed.thread_id != "thread-44444"

    GenServer.stop(adapter)
  end

  test "confirmation callbacks resolve through registered actions with resolver metadata" do
    assert {:ok, confirmation} = create_confirmation!("conf_discord_deny", "discord")

    assert {:ok, adapter} =
             Adapter.start_link(name: nil, client_opts: [mode: :stub, capture_to: self()])

    interaction = %{
      "t" => "INTERACTION_CREATE",
      "d" => %{
        "id" => "discord_callback_1",
        "token" => "interaction-token-secret",
        "guild_id" => "987654321",
        "channel_id" => "22222",
        "user" => %{"id" => "11111"},
        "data" => %{"custom_id" => "allbert:v1:deny:#{confirmation["id"]}"}
      }
    }

    assert {:ok, {:processed, event, [rendered]}} =
             Adapter.simulate_gateway_event(adapter, interaction)

    # The interaction ack is now a gateway transport obligation (M8R5/B), fired by
    # GatewayPort before dispatch — covered by the GatewayPort test. simulate_gateway_event
    # injects directly into the adapter, so only the business callback delivery is observed here.
    assert {:discord_create_message, "22222", payload} = receive_discord_capture()
    assert payload.content =~ "denied"
    assert rendered.content =~ "denied"

    GenServer.stop(adapter)

    assert event.direction == "callback"
    assert event.status == "processed"
    assert event.user_id == "alice"

    assert {:ok, resolved} = Confirmations.read(confirmation["id"])
    assert resolved["status"] == "denied"
    assert resolved["operator_resolution"]["resolver_actor"] == "alice"
    assert resolved["operator_resolution"]["resolver_channel"] == "discord"
    assert resolved["operator_resolution"]["resolver_metadata"]["callback_data"] =~ "deny"
  end

  test "typed confirmation commands resolve without runtime submission" do
    assert {:ok, confirmation} = create_confirmation!("conf_discord_typed", "discord")

    assert {:ok, adapter} =
             Adapter.start_link(name: nil, client_opts: [mode: :stub, capture_to: self()])

    command =
      Parser.simulated_message_event(%{
        message_id: "discord_typed_command",
        guild_id: "987654321",
        channel_id: "22222",
        user_id: "11111",
        application_id: "123456",
        text: "ALLBERT:DENY:#{confirmation["id"]}"
      })

    assert {:ok, {:processed, event, [rendered]}} =
             Adapter.simulate_gateway_event(adapter, command)

    assert_receive {:discord_create_message, "22222", payload}
    assert payload.content =~ "denied"
    assert rendered.content =~ "denied"
    refute_received {:runtime_request, %{text: "ALLBERT:DENY:" <> _rest}}

    GenServer.stop(adapter)

    assert event.status == "processed"
    assert {:ok, resolved} = Confirmations.read(confirmation["id"])
    assert resolved["status"] == "denied"
  end

  test "different Discord native thread channels produce different sessions" do
    assert {:ok, first} = Adapter.start_link(name: nil, client_opts: [mode: :stub])
    assert {:ok, second} = Adapter.start_link(name: nil, client_opts: [mode: :stub])

    first_event =
      Parser.simulated_message_event(%{
        guild_id: "987654321",
        channel_id: "22222",
        thread_channel_id: "thread-a",
        user_id: "11111",
        application_id: "123456",
        text: "first"
      })

    second_event =
      Parser.simulated_message_event(%{
        guild_id: "987654321",
        channel_id: "22222",
        thread_channel_id: "thread-b",
        user_id: "11111",
        application_id: "123456",
        text: "second"
      })

    assert {:ok, {:processed, first_processed, _rendered}} =
             Adapter.simulate_gateway_event(first, first_event)

    assert {:ok, {:processed, second_processed, _rendered}} =
             Adapter.simulate_gateway_event(second, second_event)

    GenServer.stop(first)
    GenServer.stop(second)

    assert first_processed.session_id != second_processed.session_id
  end

  defp configure_discord do
    assert {:ok, _setting} =
             Settings.put(
               "channels.discord.bot_token_ref",
               "secret://channels/discord/bot_token",
               %{
                 audit?: false
               }
             )

    assert {:ok, _setting} =
             Settings.put("channels.discord.application_id", "123456", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.discord.allowed_guild_ids", ["987654321"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.discord.allowed_channel_ids", ["22222"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.discord.identity_map",
               [%{"external_user_id" => "11111", "user_id" => "alice", "enabled" => true}],
               %{audit?: false}
             )

    assert {:ok, _secret} =
             Secrets.put_secret(
               "secret://channels/discord/bot_token",
               "discord-test-token",
               %{audit?: false}
             )
  end

  defp create_confirmation!(id, channel) do
    Confirmations.create(%{
      id: id,
      origin: %{actor: "alice", channel: channel, surface: "discord-test"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    })
  end

  defp gateway_state(overrides) do
    Map.merge(
      %{
        owner: self(),
        token: "discord-test-token",
        intents: 33_280,
        sequence: 7,
        session_id: "gateway-session-1",
        resume?: false,
        heartbeat_interval_ms: nil,
        last_heartbeat_acked?: true,
        heartbeat_jitter?: false,
        reconnect_max_backoff_ms: 1_000,
        client_opts: [],
        conn: nil
      },
      overrides
    )
  end

  defp fake_gateway_conn(socket) do
    %WebSockex.Conn{
      conn_mod: FakeGatewaySocket,
      socket: socket,
      transport: :tcp
    }
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)

  defp receive_discord_capture do
    receive do
      {:discord_interaction_callback, _interaction_id, _payload} = message -> message
      {:discord_create_message, _channel_id, _payload} = message -> message
    after
      100 -> flunk("expected Discord capture message")
    end
  end
end
