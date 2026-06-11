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
        "user" => %{"id" => "11111"},
        "data" => %{"custom_id" => "allbert:v1:approve:conf_123"}
      }
    }

    assert {:interaction_create, callback} = Parser.parse_gateway_event(interaction)
    assert callback.verb == :approve
    assert callback.confirmation_id == "conf_123"
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

    state = %{
      owner: self(),
      token: "discord-test-token",
      intents: 33_280,
      sequence: nil,
      session_id: nil,
      heartbeat_interval_ms: nil,
      heartbeat_jitter?: false,
      reconnect_max_backoff_ms: 1_000
    }

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
        "guild_id" => "987654321",
        "channel_id" => "22222",
        "user" => %{"id" => "11111"},
        "data" => %{"custom_id" => "allbert:v1:deny:#{confirmation["id"]}"}
      }
    }

    assert {:ok, {:processed, event, [rendered]}} =
             Adapter.simulate_gateway_event(adapter, interaction)

    assert_receive {:discord_create_message, "22222", payload}
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

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
