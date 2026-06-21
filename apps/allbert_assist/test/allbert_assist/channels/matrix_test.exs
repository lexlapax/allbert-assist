defmodule AllbertAssist.Channels.MatrixTest do
  use AllbertAssist.DataCase, async: false

  import Ecto.Query
  import Plug.Conn

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.Matrix.Adapter
  alias AllbertAssist.Channels.Matrix.Client
  alias AllbertAssist.Channels.Matrix.Parser
  alias AllbertAssist.Channels.Matrix.Renderer
  alias AllbertAssist.Channels.Outbound
  alias AllbertAssist.Confirmations
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
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
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
      restore_env(Confirmations, original_confirmations_config)
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

      query = URI.decode_query(conn.query_string)
      assert query["timeout"] == "30000"
      refute Map.has_key?(query, "filter")

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

  test "client can include a Matrix sync filter without query credentials" do
    filter = Jason.encode!(%{"room" => %{"timeline" => %{"limit" => 50}}})
    request = Client.sync_request("https://matrix.example.com", "s1", 0, filter: filter)
    query = URI.decode_query(URI.parse(request.url).query)

    assert request.path == "/_matrix/client/v3/sync"
    assert query["timeout"] == "0"
    assert query["since"] == "s1"
    assert Jason.decode!(query["filter"]) == %{"room" => %{"timeline" => %{"limit" => 50}}}
    refute request.url =~ "access_token"
  end

  test "client can build a Matrix messages pagination request without query credentials" do
    request = Client.messages_request("https://matrix.example.com", "!room:example.com", "s2", 50)
    query = URI.decode_query(URI.parse(request.url).query)

    assert request.path == "/_matrix/client/v3/rooms/%21room%3Aexample.com/messages"
    assert query["dir"] == "b"
    assert query["from"] == "s2"
    assert query["limit"] == "50"
    refute request.url =~ "access_token"
  end

  test "client can build latest Matrix messages requests without a from token" do
    request = Client.messages_request("https://matrix.example.com", "!room:example.com", nil, 50)
    query = URI.decode_query(URI.parse(request.url).query)

    assert request.path == "/_matrix/client/v3/rooms/%21room%3Aexample.com/messages"
    assert query["dir"] == "b"
    refute Map.has_key?(query, "from")
    assert query["limit"] == "50"
    refute request.url =~ "access_token"
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
      assert_matrix_sync_query(conn)

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

  test "cold poll catches up latest messages when initial sync only returns duplicates" do
    assert {:ok, %{"allowed_room_ids" => ["!room:example.com"]}} =
             Channels.channel_settings("matrix")

    assert {:ok, _event} =
             Channels.create_event(%{
               channel: "matrix",
               provider: "matrix_client_server",
               direction: "inbound",
               external_event_id: "$old-sync",
               external_user_id: "@alice:example.com",
               external_chat_id: "!room:example.com",
               external_message_id: "$old-sync",
               status: "processed",
               payload_summary: "matrix text message $old-sync"
             })

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/sync"
      assert_matrix_sync_query(conn)

      json(conn, %{
        "next_batch" => "s2",
        "rooms" => %{
          "join" => %{
            "!room:example.com" => %{
              "timeline" => %{
                "events" => [
                  %{"event_id" => "$state-sync", "type" => "m.room.history_visibility"},
                  matrix_text_event("$old-sync", "already seen")
                ]
              }
            }
          }
        }
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/rooms/%21room%3Aexample.com/messages"
      query = URI.decode_query(conn.query_string)
      assert query["dir"] == "b"
      refute Map.has_key?(query, "from")
      assert query["limit"] == "50"

      json(conn, %{
        "chunk" => [
          matrix_text_event("$caught-up", "create a note titled matrixapproval4 with body hi"),
          matrix_text_event("$old-sync", "already seen")
        ]
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"

      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["body"] ==
               "Matrix response: create a note titled matrixapproval4 with body hi"

      json(conn, %{"event_id" => "$reply-caught-up"})
    end)

    server = :"matrix-adapter-catch-up-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Adapter.start_link(
               name: server,
               auto_poll?: false,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    Req.Test.allow(__MODULE__, self(), pid)

    assert {:ok, %{processed: 1, duplicates: 2, rejected: 1, failed: 0}} =
             Adapter.poll_once(server)

    assert_receive {:runtime_request,
                    %{
                      channel: "matrix",
                      text: "create a note titled matrixapproval4 with body hi"
                    }},
                   1000

    GenServer.stop(pid)
  end

  test "adapter dedupes repeated sync events without a second runtime submission" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/sync"
      assert_matrix_sync_query(conn)

      json(conn, %{
        "next_batch" => "s2",
        "rooms" => %{
          "join" => %{
            "!room:example.com" => %{
              "timeline" => %{"events" => [matrix_text_event("$event-dupe", "hello once")]}
            }
          }
        }
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      json(conn, %{"event_id" => "$reply-dupe"})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/sync"
      assert_matrix_sync_query(conn, "s2")

      json(conn, %{
        "next_batch" => "s3",
        "rooms" => %{
          "join" => %{
            "!room:example.com" => %{
              "timeline" => %{"events" => [matrix_text_event("$event-dupe", "hello once")]}
            }
          }
        }
      })
    end)

    server = :"matrix-adapter-dupe-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Adapter.start_link(
               name: server,
               auto_poll?: false,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    Req.Test.allow(__MODULE__, self(), pid)

    assert {:ok, %{processed: 1, duplicates: 0}} = Adapter.poll_once(server)
    assert_receive {:runtime_request, %{channel: "matrix", text: "hello once"}}, 1000

    assert {:ok, %{processed: 0, duplicates: 1}} = Adapter.poll_once(server)
    refute_received {:runtime_request, %{channel: "matrix"}}

    GenServer.stop(pid)
  end

  test "typed confirmation commands resolve without runtime submission" do
    assert {:ok, confirmation} = create_confirmation!("conf_matrix_typed", "matrix")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/sync"
      assert_matrix_sync_query(conn)

      json(conn, %{
        "next_batch" => "s2",
        "rooms" => %{
          "join" => %{
            "!room:example.com" => %{
              "timeline" => %{
                "events" => [
                  matrix_text_event("$event-command", "ALLBERT:DENY:#{confirmation["id"]}")
                ]
              }
            }
          }
        }
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"

      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["body"] =~ "denied"

      json(conn, %{"event_id" => "$reply-command"})
    end)

    server = :"matrix-adapter-command-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Adapter.start_link(
               name: server,
               auto_poll?: false,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    Req.Test.allow(__MODULE__, self(), pid)

    assert {:ok, %{processed: 1, rejected: 0, failed: 0}} = Adapter.poll_once(server)
    refute_received {:runtime_request, %{text: "ALLBERT:DENY:" <> _rest}}

    assert %Event{status: "processed", direction: "callback"} =
             Repo.one(
               from event in Event,
                 where: event.channel == "matrix" and event.external_event_id == "$event-command"
             )

    assert {:ok, resolved} = Confirmations.read(confirmation["id"])
    assert resolved["status"] == "denied"

    GenServer.stop(pid)
  end

  test "Element display-name prefixed typed commands resolve without runtime submission" do
    assert {:ok, confirmation} = create_confirmation!("conf_matrix_prefixed", "matrix")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/sync"
      assert_matrix_sync_query(conn)

      json(conn, %{
        "next_batch" => "s2",
        "rooms" => %{
          "join" => %{
            "!room:example.com" => %{
              "timeline" => %{
                "events" => [
                  matrix_text_event(
                    "$event-prefixed-command",
                    "Lex Lapax:ALLBERT:DENY:#{confirmation["id"]}"
                  )
                ]
              }
            }
          }
        }
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"

      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["body"] =~ "denied"

      json(conn, %{"event_id" => "$reply-prefixed-command"})
    end)

    server = :"matrix-adapter-prefixed-command-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Adapter.start_link(
               name: server,
               auto_poll?: false,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    Req.Test.allow(__MODULE__, self(), pid)

    assert {:ok, %{processed: 1, rejected: 0, failed: 0}} = Adapter.poll_once(server)
    refute_received {:runtime_request, %{text: "Lex Lapax:ALLBERT:DENY:" <> _rest}}

    assert %Event{status: "processed", direction: "callback"} =
             Repo.one(
               from event in Event,
                 where:
                   event.channel == "matrix" and
                     event.external_event_id == "$event-prefixed-command"
             )

    assert {:ok, resolved} = Confirmations.read(confirmation["id"])
    assert resolved["status"] == "denied"

    GenServer.stop(pid)
  end

  test "adapter records delivery failure without automatic provider retry" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/sync"
      assert_matrix_sync_query(conn)

      json(conn, %{
        "next_batch" => "s2",
        "rooms" => %{
          "join" => %{
            "!room:example.com" => %{
              "timeline" => %{"events" => [matrix_text_event("$event-fail", "fail once")]}
            }
          }
        }
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"

      conn
      |> put_status(503)
      |> json(%{"errcode" => "M_UNAVAILABLE", "error" => "temporarily unavailable"})
    end)

    server = :"matrix-adapter-fail-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Adapter.start_link(
               name: server,
               auto_poll?: false,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    Req.Test.allow(__MODULE__, self(), pid)

    assert {:ok, %{processed: 0, failed: 1}} = Adapter.poll_once(server)

    assert %Event{status: "failed", error: error} =
             Repo.one(
               from event in Event,
                 where: event.channel == "matrix" and event.external_event_id == "$event-fail"
             )

    assert error =~ "matrix_error"

    GenServer.stop(pid)
  end

  test "generic outbound sends through Channels.Outbound" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"

      assert conn.request_path ==
               "/_matrix/client/v3/rooms/%21room%3Aexample.com/send/m.room.message/txn-out"

      assert get_req_header(conn, "authorization") == ["Bearer matrix-secret"]

      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["msgtype"] == "m.text"
      assert decoded["body"] == "v055 outbound check"

      json(conn, %{"event_id" => "$outbound-event"})
    end)

    assert {:ok, receipt} =
             Outbound.send("matrix", "!room:example.com", "v055 outbound check",
               req_options: [plug: {Req.Test, __MODULE__}],
               txn_id: "txn-out"
             )

    assert receipt.channel == "matrix"
    assert receipt.target == "!room:example.com"
    assert receipt.event_id == "$outbound-event"
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

  defp create_confirmation!(id, channel) do
    Confirmations.create(%{
      id: id,
      origin: %{actor: "alice", channel: channel, surface: "matrix-test"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    })
  end

  defp assert_matrix_sync_query(conn, since \\ nil) do
    query = URI.decode_query(conn.query_string)
    filter = Jason.decode!(query["filter"])

    assert query["timeout"] == "30000"
    assert query["since"] == since

    assert filter == %{
             "room" => %{
               "timeline" => %{
                 "limit" => 50,
                 "types" => ["m.room.message", "m.room.encrypted"]
               }
             }
           }
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
