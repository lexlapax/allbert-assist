defmodule AllbertAssist.Channels.SignalTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  import Ecto.Query
  import Plug.Conn

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.Signal.Adapter
  alias AllbertAssist.Channels.Signal.Client
  alias AllbertAssist.Channels.Signal.Daemon
  alias AllbertAssist.Channels.Signal.Parser
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Signal, as: SignalPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Trace
  alias AllbertSignal.Settings.Fragment, as: SignalSettingsFragment

  @aci "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001"
  @local_aci "5c4e9f85-f2a7-4f58-a0d8-2a6f4b4d8001"

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-signal-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    assert {:ok, "allbert.signal"} = PluginRegistry.register_module(SignalPlugin)
    Fragments.clear_cache()

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})

        {:ok,
         %{
           message: "Signal response: #{request.text}",
           status: :completed,
           assistant_message_id: Ecto.UUID.generate(),
           thread_id: request[:thread_id] || Ecto.UUID.generate()
         }}
      end
    )

    configure_signal!(root)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "plugin descriptor declares Signal daemon and E2EE channel contract" do
    assert [descriptor] = SignalPlugin.channels()

    assert descriptor.channel_id == "signal"
    assert descriptor.provider == "signal_cli_jsonrpc"
    assert descriptor.primitives == [:typed_command, :link, :list]
    assert descriptor.threading == :reply_chain
    assert descriptor.trust_class == :e2ee_origin
    assert descriptor.reply_key_type == :timestamp
    assert descriptor.settings_prefix == "channels.signal"
    assert descriptor.identity_map_key == "channels.signal.identity_map"
    assert descriptor.session_strategy == {:signal_aci, prefix: "ch_si_"}

    assert {:ok, descriptor} = Channels.channel_descriptor("signal")
    assert descriptor.trust_class == :e2ee_origin
  end

  test "settings fragment reports required fields when Signal is enabled" do
    diagnostics =
      SignalSettingsFragment.required_when_enabled(%{
        "enabled" => true,
        "account_identifier" => "",
        "control_mode" => "loopback_http",
        "loopback_http_base_url" => "",
        "control_auth_ref" => ""
      })

    assert :missing_account_identifier in diagnostics
    assert :missing_loopback_http_base_url in diagnostics
    assert :missing_control_auth_ref in diagnostics
  end

  test "client builds signal-cli JSON-RPC send requests with timestamp quote params" do
    assert {:ok, response} =
             Client.send_message("+15551234567", @aci, "hello signal",
               mode: :stub,
               id: "rpc-1",
               quote_timestamp_ms: 1_781_477_600_000,
               quote_author: @aci
             )

    request = response["request"]
    assert request["method"] == "send"
    assert request["params"]["recipient"] == [@aci]
    assert request["params"]["account"] == "+15551234567"
    assert request["params"]["quoteTimestamp"] == 1_781_477_600_000
    assert request["params"]["quoteAuthor"] == @aci
    assert request["params"]["message"] == "[REDACTED]"
    refute inspect(response) =~ "hello signal"
  end

  test "parser extracts ACI-keyed receive notifications" do
    notification =
      Parser.simulated_receive_notification(%{
        source_aci: "aci:" <> @aci,
        source_number: "+15550001111",
        timestamp_ms: 1_781_477_600_000,
        text: "hello signal"
      })

    assert [{:text_message, fields}] = Parser.parse_notification(notification)
    assert fields.external_user_id == @aci
    assert fields.external_message_id == "1781477600000"
    assert fields.source_aci == @aci
    assert fields.text == "hello signal"
  end

  test "daemon custody uses Allbert Home and constrains socket/key permissions", %{root: root} do
    data_dir = Path.join(root, "signal")
    File.mkdir_p!(data_dir)
    key_file = Path.join(data_dir, "account.db")
    socket_file = Path.join(data_dir, "signal-cli.sock")
    File.write!(key_file, "fixture")
    File.write!(socket_file, "")
    File.chmod!(key_file, 0o644)
    File.chmod!(socket_file, 0o600)

    custody = Daemon.ensure_custody!(%{"data_dir" => data_dir})

    control =
      Daemon.control_diagnostics(%{"control_mode" => "socket", "socket_path" => socket_file})

    assert custody.directory_mode == 0o700
    assert custody.key_files["account.db"] == 0o600
    assert control.ok?
    assert control.local_only?
    assert control.socket_mode == 0o600

    child_spec = Daemon.daemon_child_spec(%{"data_dir" => data_dir, "socket_path" => socket_file})

    assert child_spec.start ==
             {MuonTrap.Daemon, :start_link,
              [
                "signal-cli",
                ["--config", data_dir, "daemon", "--socket", socket_file],
                [log_output: :debug, log_prefix: "signal-cli: "]
              ]}
  end

  test "adapter processes stubbed daemon inbound, quotes by timestamp, and stamps e2ee_origin" do
    notification =
      Parser.simulated_receive_notification(%{
        source_aci: @aci,
        timestamp_ms: 1_781_477_600_000,
        text: "hello signal"
      })

    server = :"signal-adapter-#{System.unique_integer([:positive])}"

    assert {:ok, pid} = Adapter.start_link(name: server, client_opts: [mode: :stub])

    assert {:ok, %{processed: 1, duplicates: 0, rejected: 0, failed: 0}} =
             Adapter.simulate_daemon_notification(server, notification)

    assert_receive {:runtime_request, request}, 1000
    assert request.channel == "signal"
    assert request.user_id == "alice"
    assert request.text == "hello signal"
    assert request.metadata.trust_class == :e2ee_origin
    assert request.metadata.provider_thread_ref.quote_timestamp_ms == 1_781_477_600_000
    assert request.metadata.provider_thread_ref.author_aci == @aci
    refute inspect(request.metadata) =~ "+15550001111"

    assert %ConversationMessageRef{trust_class: "e2ee_origin"} =
             Repo.one(
               from ref in ConversationMessageRef,
                 where: ref.channel == "signal" and ref.direction == "out"
             )

    assert %Event{external_user_id: @aci, status: "processed"} =
             Repo.one(from event in Event, where: event.channel == "signal")

    GenServer.stop(pid)
  end

  test "adapter dedupes repeated daemon notifications without a second runtime submission" do
    notification =
      Parser.simulated_receive_notification(%{
        source_aci: @aci,
        timestamp_ms: 1_781_477_700_000,
        text: "hello once"
      })

    server = :"signal-adapter-dupe-#{System.unique_integer([:positive])}"

    assert {:ok, pid} = Adapter.start_link(name: server, client_opts: [mode: :stub])

    assert {:ok, %{processed: 1, duplicates: 0}} =
             Adapter.simulate_daemon_notification(server, notification)

    assert_receive {:runtime_request, %{channel: "signal", text: "hello once"}}, 1000

    assert {:ok, %{processed: 0, duplicates: 1}} =
             Adapter.simulate_daemon_notification(server, notification)

    refute_received {:runtime_request, %{channel: "signal"}}

    GenServer.stop(pid)
  end

  test "adapter records delivery failure without automatic provider retry" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/rpc"

      conn
      |> put_status(503)
      |> json(%{"error" => %{"message" => "temporarily unavailable"}})
    end)

    notification =
      Parser.simulated_receive_notification(%{
        source_aci: @aci,
        timestamp_ms: 1_781_477_800_000,
        text: "fail once"
      })

    server = :"signal-adapter-fail-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Adapter.start_link(
               name: server,
               client_opts: [
                 mode: :loopback_http,
                 base_url: "http://127.0.0.1:8080",
                 plug: {Req.Test, __MODULE__}
               ]
             )

    Req.Test.allow(__MODULE__, self(), pid)

    assert {:ok, %{processed: 0, failed: 1}} =
             Adapter.simulate_daemon_notification(server, notification)

    assert %Event{status: "failed", error: error} =
             Repo.one(
               from event in Event,
                 where: event.channel == "signal" and event.external_message_id == "1781477800000"
             )

    assert error =~ "signal_http_error"

    GenServer.stop(pid)
  end

  defp configure_signal!(root) do
    assert {:ok, _setting} =
             Settings.put("channels.signal.account_identifier", "+15551234567", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.signal.local_aci", @local_aci, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.signal.data_dir", Path.join(root, "signal"), %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.signal.identity_map",
               [%{external_user_id: @aci, user_id: "alice"}],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("channels.signal.allowed_aci_ids", [@aci], %{audit?: false})

    assert {:ok, _setting} = Settings.put("channels.signal.enabled", true, %{audit?: false})
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp json(conn, body) do
    status = conn.status || 200

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
