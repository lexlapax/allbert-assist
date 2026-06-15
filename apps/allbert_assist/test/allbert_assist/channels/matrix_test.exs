defmodule AllbertAssist.Channels.MatrixTest do
  use AllbertAssist.DataCase, async: false

  import Ecto.Query
  import Plug.Conn

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Matrix.Adapter
  alias AllbertAssist.Channels.Matrix.Client
  alias AllbertAssist.Channels.Matrix.Parser
  alias AllbertAssist.Channels.Matrix.Renderer
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Matrix, as: MatrixPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace
  alias AllbertMatrix.Settings.Fragment, as: MatrixSettingsFragment

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
        "allbert-matrix-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    assert {:ok, "allbert.matrix"} = PluginRegistry.register_module(MatrixPlugin)
    Fragments.clear_cache()

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})
        {:ok, %{message: "Matrix response: #{request.text}", status: :completed}}
      end
    )

    configure_matrix!()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "plugin descriptor declares Matrix channel contract" do
    assert [descriptor] = MatrixPlugin.channels()

    assert descriptor.channel_id == "matrix"
    assert descriptor.provider == "matrix_client_server"
    assert descriptor.primitives == [:typed_command, :link, :list]
    assert descriptor.threading == :native_threads
    assert descriptor.trust_class == :server_readable
    assert descriptor.settings_prefix == "channels.matrix"
    assert descriptor.identity_map_key == "channels.matrix.identity_map"
    assert descriptor.session_strategy == {:matrix_room, prefix: "ch_mx_"}

    assert {:ok, descriptor} = Channels.channel_descriptor("matrix")
    assert descriptor.threading == :native_threads
  end

  test "settings fragment reports required fields when Matrix is enabled" do
    diagnostics =
      MatrixSettingsFragment.required_when_enabled(%{
        "enabled" => true,
        "homeserver_url" => "",
        "access_token_ref" => "",
        "allowed_room_ids" => []
      })

    assert :missing_homeserver_url in diagnostics
    assert :missing_access_token_ref in diagnostics
    assert :missing_allowed_room_ids in diagnostics
  end

  test "client uses bearer auth and Matrix v3 paths without query credentials" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/_matrix/client/v3/sync"
      assert get_req_header(conn, "authorization") == ["Bearer matrix-secret"]
      refute conn.query_string =~ "access_token"

      json(conn, %{"next_batch" => "s1", "rooms" => %{"join" => %{}}})
    end)

    assert {:ok, %{"next_batch" => "s1"}} =
             Client.sync("https://matrix.example.com", "matrix-secret", nil, 30_000,
               plug: {Req.Test, __MODULE__}
             )

    request =
      Client.send_message_request("https://matrix.example.com", "!room:example.com", "txn-1", %{
        "msgtype" => "m.text",
        "body" => "hello"
      })

    assert request.method == :put

    assert request.path ==
             "/_matrix/client/v3/rooms/%21room%3Aexample.com/send/m.room.message/txn-1"

    assert inspect(request) =~ "[REDACTED]"
    refute inspect(request) =~ "matrix-secret"
  end

  test "parser extracts text events and rejects encrypted events" do
    events =
      Parser.parse_sync(%{
        "next_batch" => "s2",
        "rooms" => %{
          "join" => %{
            "!room:example.com" => %{
              "timeline" => %{
                "events" => [
                  matrix_text_event("$event1", "hello"),
                  %{"event_id" => "$event2", "type" => "m.room.encrypted"}
                ]
              }
            }
          }
        }
      })

    assert [{:text_message, fields}, {:unsupported, unsupported}] = events
    assert fields.external_user_id == "@alice:example.com"
    assert fields.room_id == "!room:example.com"
    assert fields.text == "hello"
    assert unsupported.type == "encrypted_not_supported"
  end

  test "renderer emits Matrix thread relation with reply fallback" do
    content =
      Renderer.message_content("hello", %{
        thread_root_event_id: "$root",
        reply_to_event_id: "$parent"
      })

    assert content["msgtype"] == "m.text"

    assert content["m.relates_to"] == %{
             "rel_type" => "m.thread",
             "event_id" => "$root",
             "m.in_reply_to" => %{"event_id" => "$parent"},
             "is_falling_back" => true
           }
  end

  test "adapter processes fixture /sync, sends threaded reply, and records refs" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/sync"
      assert get_req_header(conn, "authorization") == ["Bearer matrix-secret"]

      json(conn, %{
        "next_batch" => "s2",
        "rooms" => %{
          "join" => %{
            "!room:example.com" => %{
              "timeline" => %{
                "events" => [
                  matrix_text_event("$event1", "hello matrix")
                ]
              }
            }
          }
        }
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"

      assert conn.request_path =~
               "/_matrix/client/v3/rooms/%21room%3Aexample.com/send/m.room.message/"

      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["body"] == "Matrix response: hello matrix"
      assert decoded["m.relates_to"]["rel_type"] == "m.thread"
      assert decoded["m.relates_to"]["event_id"] == "$event1"
      assert decoded["m.relates_to"]["m.in_reply_to"] == %{"event_id" => "$event1"}

      json(conn, %{"event_id" => "$reply1"})
    end)

    server = :"matrix-adapter-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Adapter.start_link(
               name: server,
               auto_poll?: false,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    Req.Test.allow(__MODULE__, self(), pid)

    assert {:ok, %{processed: 1, duplicates: 0, rejected: 0, failed: 0}} =
             Adapter.poll_once(server)

    assert_receive {:runtime_request, request}, 1000
    assert request.channel == "matrix"
    assert request.user_id == "alice"
    assert request.text == "hello matrix"
    assert request.metadata.provider_thread_ref.provider == "matrix"

    assert %ConversationMessageRef{} =
             Repo.one(
               from ref in ConversationMessageRef,
                 where: ref.channel == "matrix" and ref.provider_message_id == "$reply1"
             )

    GenServer.stop(pid)
  end

  defp configure_matrix! do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/matrix/access_token", "matrix-secret", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("channels.matrix.homeserver_url", "https://matrix.example.com", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put(
               "channels.matrix.access_token_ref",
               "secret://channels/matrix/access_token",
               %{
                 audit?: false
               }
             )

    assert {:ok, _setting} =
             Settings.put("channels.matrix.allowed_room_ids", ["!room:example.com"], %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put(
               "channels.matrix.identity_map",
               [
                 %{external_user_id: "@alice:example.com", user_id: "alice"}
               ],
               %{audit?: false}
             )

    assert {:ok, _setting} = Settings.put("channels.matrix.enabled", true, %{audit?: false})
  end

  defp matrix_text_event(event_id, text) do
    Parser.simulated_message_event(%{
      event_id: event_id,
      sender: "@alice:example.com",
      text: text
    })
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
