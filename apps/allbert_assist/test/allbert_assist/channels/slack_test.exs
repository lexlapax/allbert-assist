defmodule AllbertAssist.Channels.SlackTest do
  use AllbertAssist.DataCase, async: false

  import Ecto.Query

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Slack.Adapter
  alias AllbertAssist.Channels.Slack.Client
  alias AllbertAssist.Channels.Slack.Client.SocketModePort
  alias AllbertAssist.Channels.Slack.Parser
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
    assert {:ok, "allbert.slack"} = PluginRegistry.register_module(AllbertAssist.Plugins.Slack)
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
    assert [descriptor] = AllbertAssist.Plugins.Slack.channels()

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
      AllbertSlack.Settings.Fragment.required_when_enabled(%{
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
