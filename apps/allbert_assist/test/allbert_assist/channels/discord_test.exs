defmodule AllbertAssist.Channels.DiscordTest do
  use AllbertAssist.DataCase, async: false

  import Ecto.Query

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Discord.Adapter
  alias AllbertAssist.Channels.Discord.Client
  alias AllbertAssist.Channels.Discord.Client.GatewayPort
  alias AllbertAssist.Channels.Discord.Parser
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Trace

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
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

    assert {:ok, "allbert.discord"} =
             PluginRegistry.register_module(AllbertAssist.Plugins.Discord)

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
    assert [descriptor] = AllbertAssist.Plugins.Discord.channels()

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
      AllbertDiscord.Settings.Fragment.required_when_enabled(%{
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
    assert request.channel_thread_ref.receiver_account_ref == "discord:app:123456:guild:987654321"

    refs =
      ConversationMessageRef
      |> where([ref], ref.channel == "discord")
      |> order_by([ref], asc: ref.direction)
      |> Repo.all()

    assert Enum.any?(refs, &(&1.direction == "in"))
    assert Enum.any?(refs, &(&1.direction == "out"))
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
             Settings.put(
               "channels.discord.identity_map",
               [%{"external_user_id" => "11111", "user_id" => "alice", "enabled" => true}],
               %{audit?: false}
             )
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
