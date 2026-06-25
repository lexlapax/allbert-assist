defmodule AllbertAssist.PublicProtocol.AcpStdioServerTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.PublicProtocol.Acp.Server
  alias AllbertAssist.PublicProtocol.ResultReadback
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    parent = self()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-acp-stdio-server-#{System.unique_integer([:positive])}"
      )

    runner = fn _signal, request ->
      send(parent, {:runtime_request, request})

      {:ok,
       %{
         message: "ACP runtime response: #{request.text}",
         status: :completed,
         actions: []
       }}
    end

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Runtime, original_runtime_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "initialize negotiates ACP v1 and records client identity in process state" do
    {:ok, [response], state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 0,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => 1,
            "clientInfo" => %{"name" => "zed-fixture"}
          }
        },
        Server.new_state()
      )

    assert response["result"]["protocolVersion"] == 1
    assert response["result"]["agentCapabilities"]["promptCapabilities"] == %{}
    assert state.initialized?
    assert state.client_id == "zed-fixture"
  end

  test "default-off stdio surface rejects session creation before runtime work" do
    state = initialized_state()

    {:ok, [response], _state} =
      Server.handle_message(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "session/new", "params" => %{}},
        state
      )

    assert response["error"]["data"]["code"] == "surface_disabled"
    refute_received {:runtime_request, _request}

    assert %Event{
             channel: "acp_stdio",
             status: "rejected",
             external_user_id: "zed-fixture",
             user_id: "public-protocol:zed-fixture",
             payload_summary: "session/new rejected",
             reason: "surface_disabled"
           } = Repo.get_by(Event, channel: "acp_stdio", status: "rejected")
  end

  test "session/new rejects client-supplied MCP servers and accepts inert cwd metadata" do
    enable_acp_stdio!()
    state = initialized_state()

    {:ok, [rejected], state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "session/new",
          "params" => %{
            "cwd" => "/tmp/project",
            "mcpServers" => [%{"name" => "filesystem", "command" => "mcp"}]
          }
        },
        state
      )

    assert rejected["error"]["data"]["code"] == "mcpservers_no_authority"

    assert %Event{
             channel: "acp_stdio",
             status: "rejected",
             payload_summary: "session/new rejected",
             reason: "mcpservers_no_authority"
           } = Repo.get_by(Event, channel: "acp_stdio", status: "rejected")

    {:ok, [accepted], state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "session/new",
          "params" => %{"cwd" => "/tmp/project", "mcpServers" => []}
        },
        state
      )

    session_id = accepted["result"]["sessionId"]
    assert session_id =~ "acp_sess_"
    assert state.sessions[session_id].cwd == "/tmp/project"
  end

  test "session/prompt maps text content to one runtime turn and returns ACP updates" do
    enable_acp_stdio!()
    {session_id, state} = started_session()

    {:ok, [update, response], _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => session_id,
            "prompt" => [%{"type" => "text", "text" => "Explain this code"}]
          }
        },
        state
      )

    assert update["method"] == "session/update"
    assert update["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
    assert update["params"]["update"]["content"]["type"] == "text"
    assert update["params"]["update"]["content"]["text"] =~ "Explain this code"
    assert response["result"]["stopReason"] == "end_turn"

    assert_received {:runtime_request,
                     %{
                       channel: :acp_stdio,
                       text: "Explain this code",
                       metadata: %{
                         public_protocol: %{surface: "acp_stdio", client_id: "zed-fixture"}
                       }
                     }}

    assert %Event{
             channel: "acp_stdio",
             status: "processed",
             external_user_id: "zed-fixture",
             user_id: "public-protocol:zed-fixture",
             session_id: ^session_id
           } =
             Repo.get_by(Event, channel: "acp_stdio", status: "processed")
  end

  test "session/prompt returns structured runtime errors and records failed audit events" do
    enable_acp_stdio!()
    {session_id, state} = started_session()
    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runtime_request, request})
        {:error, :runtime_down}
      end
    )

    {:ok, [response], _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 6,
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => session_id,
            "prompt" => [%{"type" => "text", "text" => "Explain this code"}]
          }
        },
        state
      )

    assert response["error"]["data"]["code"] == "runtime_error"
    assert response["error"]["message"] =~ "ACP prompt failed"
    assert_received {:runtime_request, %{text: "Explain this code"}}

    assert %Event{channel: "acp_stdio", status: "failed", error: ":runtime_down"} =
             Repo.get_by(Event, channel: "acp_stdio", status: "failed")
  end

  test "non-text prompt content is rejected before runtime" do
    enable_acp_stdio!()
    {session_id, state} = started_session()

    {:ok, [response], _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => session_id,
            "prompt" => [
              %{
                "type" => "resource",
                "resource" => %{"uri" => "file:///tmp/a.ex", "text" => "def a"}
              }
            ]
          }
        },
        state
      )

    assert response["error"]["data"]["code"] == "unsupported_content_block"
    refute_received {:runtime_request, _request}

    assert %Event{
             channel: "acp_stdio",
             status: "rejected",
             external_user_id: "zed-fixture",
             user_id: "public-protocol:zed-fixture",
             session_id: ^session_id,
             reason: "unsupported_content_block"
           } = Repo.get_by(Event, channel: "acp_stdio", status: "rejected")
  end

  test "confirmation-pending prompt creates client-scoped public readback" do
    enable_acp_stdio!()
    {session_id, state} = started_session()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, _request ->
        {:ok,
         %{
           message: "Approval required.",
           status: :needs_confirmation,
           approval_handoff: %{confirmation_id: "conf_acp_fixture"},
           actions: []
         }}
      end
    )

    {:ok, [_update, permission_request, response], state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => session_id,
            "prompt" => [%{"type" => "text", "text" => "Do gated work"}]
          }
        },
        state
      )

    assert permission_request["method"] == "session/request_permission"

    assert permission_request["params"]["_meta"]["allbertAuthority"] ==
             "operator_confirmation_required"

    assert response["result"]["allbertStatus"] == "confirmation_pending"
    assert response["result"]["allbertPublicCallId"] =~ "pubcall_"

    assert permission_request["params"]["_meta"]["allbertPublicCallId"] ==
             response["result"]["allbertPublicCallId"]

    assert {:ok, readback} =
             ResultReadback.get_for_client(
               response["result"]["allbertPublicCallId"],
               "acp_stdio",
               "zed-fixture"
             )

    assert readback.status == :pending

    {:ok, [], _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => permission_request["id"],
          "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "acknowledge"}}
        },
        state
      )
  end

  test "session/request_permission cannot authorize Allbert execution" do
    enable_acp_stdio!()
    {session_id, state} = started_session()

    {:ok, [response], _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 6,
          "method" => "session/request_permission",
          "params" => %{
            "sessionId" => session_id,
            "options" => [%{"optionId" => "allow", "kind" => "allow_once"}]
          }
        },
        state
      )

    assert response["error"]["data"]["code"] == "client_permission_not_authority"
    refute_received {:runtime_request, _request}

    assert %Event{
             channel: "acp_stdio",
             status: "rejected",
             session_id: ^session_id,
             payload_summary: "session/request_permission rejected",
             reason: "client_permission_not_authority"
           } = Repo.get_by(Event, channel: "acp_stdio", status: "rejected")
  end

  test "unsupported methods record rejected audit events before runtime" do
    enable_acp_stdio!()
    state = initialized_state()

    {:ok, [response], _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "session/unsupported",
          "params" => %{}
        },
        state
      )

    assert response["error"]["data"]["code"] == "unsupported_method"
    refute_received {:runtime_request, _request}

    assert %Event{
             channel: "acp_stdio",
             status: "rejected",
             payload_summary: "session/unsupported rejected",
             reason: "unsupported_method"
           } = Repo.get_by(Event, channel: "acp_stdio", status: "rejected")
  end

  test "stdio line handler emits newline-delimited JSON-RPC only" do
    {:ok, [line], _state} =
      Server.handle_line(
        ~s({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}) <> "\n",
        Server.new_state()
      )

    assert String.ends_with?(line, "\n")

    assert {:ok, %{"jsonrpc" => "2.0", "result" => %{"protocolVersion" => 1}}} =
             Jason.decode(line)
  end

  defp initialized_state do
    {:ok, [_response], state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 0,
          "method" => "initialize",
          "params" => %{"protocolVersion" => 1, "clientInfo" => %{"name" => "zed-fixture"}}
        },
        Server.new_state()
      )

    state
  end

  defp started_session do
    state = initialized_state()

    {:ok, [response], state} =
      Server.handle_message(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "session/new", "params" => %{}},
        state
      )

    {response["result"]["sessionId"], state}
  end

  defp enable_acp_stdio! do
    assert {:ok, _setting} = Settings.put("acp_server.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("acp_server.stdio.enabled", true, %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
