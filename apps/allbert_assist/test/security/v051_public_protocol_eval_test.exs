defmodule AllbertAssist.Security.V051PublicProtocolEvalTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :security_eval_serial
  @moduletag :app_env_serial
  @moduletag :global_process_serial
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.PublicProtocol.Acp.Mapping, as: AcpMapping
  alias AllbertAssist.PublicProtocol.Acp.Server, as: AcpServer
  alias AllbertAssist.PublicProtocol.ExposureFilter
  alias AllbertAssist.PublicProtocol.HttpIngress
  alias AllbertAssist.PublicProtocol.Mcp.ProtocolVersions
  alias AllbertAssist.PublicProtocol.Mcp.Runtime, as: McpRuntime
  alias AllbertAssist.PublicProtocol.OpenAI.Mapping, as: OpenAIMapping
  alias AllbertAssist.PublicProtocol.RateLimiter
  alias AllbertAssist.PublicProtocol.ResultReadback
  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Runtime
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings

  @eval_groups [
    exposure: [
      "public-surface-empty-exposure-by-default-001",
      "public-surface-internals-exposure-deny-001",
      "public-surface-settings-actions-deny-001",
      "public-surface-dynamic-action-exposure-deny-001",
      "agui-bridge-remains-internal-001"
    ],
    http_ingress: [
      "http-token-redaction-001",
      "http-revoked-token-deny-001",
      "http-token-cli-redaction-001",
      "public-surface-rate-limit-before-runtime-001",
      "mcp-http-origin-validate-001",
      "mcp-http-session-version-contract-001",
      "mcp-http-unsupported-protocol-version-deny-001"
    ],
    readback: [
      "mcp-server-self-approval-deny-001",
      "openai-api-self-approval-deny-001",
      "public-surface-cross-client-confusion-deny-001",
      "public-surface-result-readback-client-scoped-001",
      "public-surface-no-result-before-approval-001",
      "public-surface-result-readback-expiry-001"
    ],
    mcp: [
      "mcp-server-prompt-injection-no-tool-escalation-001",
      "mcp-server-unsupported-prompts-resources-deny-001",
      "memory-namespace-scope-leak-deny-001"
    ],
    openai: [
      "openai-api-no-tool-escalation-001",
      "openai-api-unsupported-tools-functions-deny-001",
      "openai-api-tool-role-messages-deny-001",
      "openai-api-non-text-content-deny-001",
      "openai-api-error-shape-001",
      "openai-api-model-selection-advisory-001"
    ],
    acp: [
      "acp-server-self-approval-deny-001",
      "acp-permission-response-not-authoritative-001",
      "acp-cwd-no-filesystem-authority-001",
      "acp-session-mcpservers-no-authority-001",
      "acp-session-mcpservers-not-imported-001",
      "acp-capability-advertisement-minimal-001",
      "acp-non-text-content-deny-001"
    ]
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()

  @now ~U[2026-06-09 12:00:00Z]

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    parent = self()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v051-public-protocol-eval-#{System.unique_integer([:positive])}"
      )

    runner = fn _signal, request ->
      send(parent, {:runtime_request, request})

      {:ok,
       %{
         message: "v0.51 eval runtime response: #{request.text}",
         status: :completed,
         actions: []
       }}
    end

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)
    RateLimiter.reset_for_test()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Runtime, original_runtime_config)
      RateLimiter.reset_for_test()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "v0.51 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v051)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.surface == :public_protocol))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "public exposure defaults off and internals stay denied before allowlist" do
    assert_eval_group!(:exposure)

    refute McpRuntime.surface_enabled?("mcp_stdio")
    refute McpRuntime.surface_enabled?("mcp_http")
    refute AcpMapping.surface_enabled?()
    assert {:ok, []} = McpRuntime.enabled_tools("mcp_stdio")
    assert {:ok, []} = McpRuntime.enabled_resources("mcp_stdio")

    assert {:error, {:non_exposable_tools, rejected}} =
             ExposureFilter.filter_tools([
               "list_settings",
               "set_provider_credential",
               "show_dynamic_draft"
             ])

    assert Enum.map(rejected, & &1.name) == [
             "list_settings",
             "set_provider_credential",
             "show_dynamic_draft"
           ]

    assert {:ok, direct_answer} = Registry.capability("direct_answer")
    assert direct_answer.exposure == :agent
  end

  test "HTTP public ingress enforces token, revocation, rate, origin, and version before runtime" do
    assert_eval_group!(:http_ingress)

    enable_mcp_http!()

    assert {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())
    assert created.redacted_token == "[REDACTED]"
    refute inspect(TokenAuth.list("mcp_http")) =~ created.token

    set_rate_limit!("claude", %{"limit" => 1, "period_ms" => 60_000, "burst" => 0})

    headers = [
      {"x-allbert-client-id", "claude"},
      {"authorization", "Bearer #{created.token}"}
    ]

    assert {:ok, auth} = HttpIngress.authenticate("mcp_http", headers)
    assert :ok = HttpIngress.rate_limit(auth)
    assert {:error, :rate_limited} = HttpIngress.rate_limit(auth)
    refute_received {:runtime_request, _request}

    assert {:ok, _revoked} = TokenAuth.revoke("mcp_http", "claude", context())
    assert {:error, :client_disabled} = HttpIngress.authenticate("mcp_http", headers)

    assert {:error, :origin_denied} =
             HttpIngress.validate_origin([{"origin", "https://evil.example"}], "127.0.0.1")

    assert :ok =
             HttpIngress.validate_mcp_protocol_version([{"mcp-protocol-version", "2025-06-18"}])

    assert {:error, %{message: "Unsupported MCP protocol version."}} =
             HttpIngress.validate_mcp_protocol_version([{"mcp-protocol-version", "2025-11-25"}])
  end

  test "result readback stays client-scoped, pending-before-approval, and expiry-safe" do
    assert_eval_group!(:readback)

    assert {:ok, call_result} =
             ResultReadback.create(
               %{
                 surface: "openai_api",
                 client_id: "local-client",
                 action_label: "chat.completion",
                 result: %{message: "must not be visible while pending"}
               },
               now: @now,
               ttl_ms: 1_000
             )

    assert {:ok, pending} =
             ResultReadback.get_for_client(call_result.id, "openai_api", "local-client",
               now: @now
             )

    assert pending.status == :pending
    refute Map.has_key?(pending, :result)

    assert {:error, :not_authorized} =
             ResultReadback.get_for_client(call_result.id, "openai_api", "other-client",
               now: @now
             )

    assert {:error, :not_authorized} =
             ResultReadback.get_for_client(call_result.id, "mcp_http", "local-client", now: @now)

    assert {:ok, expired} =
             ResultReadback.get_for_client(
               call_result.id,
               "openai_api",
               "local-client",
               now: DateTime.add(@now, 2, :second)
             )

    assert expired.status == :expired
    refute Map.has_key?(expired, :result)
    refute inspect(expired) =~ "must not be visible"
  end

  test "MCP public server exposes only allowlisted tools and memory namespace resources" do
    assert_eval_group!(:mcp)

    enable_mcp_stdio!()
    allow_tools!(["direct_answer"])
    allow_namespaces!(["stocksage.stocksage"])

    assert {:ok, [tool]} = McpRuntime.enabled_tools("mcp_stdio")
    assert tool.name == "direct_answer"

    assert {:error, {:non_exposable_tools, rejected}} =
             ExposureFilter.filter_tools(["direct_answer", "list_settings"])

    assert Enum.map(rejected, & &1.name) == ["list_settings"]

    assert {:ok, [resource]} = McpRuntime.enabled_resources("mcp_stdio")
    assert resource.uri == "allbert-memory://stocksage/stocksage"
    refute resource.uri =~ "artifact"

    assert ProtocolVersions.supported() == ["2025-06-18", "2025-03-26"]

    assert {:error, %{message: "Unsupported MCP protocol version."}} =
             ProtocolVersions.validate("2025-11-25")
  end

  test "OpenAI-compatible API rejects tool, media, model, and authority-changing fields" do
    assert_eval_group!(:openai)

    assert {:ok, _setting} =
             Settings.put("openai_api.models_enabled", ["local"], %{audit?: false})

    base = %{"model" => "local", "messages" => [%{"role" => "user", "content" => "hello"}]}

    assert {:error, tools_error} =
             OpenAIMapping.parse_chat_request(Map.put(base, "tools", []), %{client_id: "local"})

    assert tools_error.param == "tools"
    assert OpenAIMapping.error_body(tools_error)["error"]["code"] == "unsupported_parameter"

    assert {:error, role_error} =
             OpenAIMapping.parse_chat_request(
               %{"model" => "local", "messages" => [%{"role" => "tool", "content" => "done"}]},
               %{client_id: "local"}
             )

    assert role_error.code == "unsupported_role"

    assert {:error, assistant_tool_error} =
             OpenAIMapping.parse_chat_request(
               %{
                 "model" => "local",
                 "messages" => [%{"role" => "assistant", "content" => "done", "tool_calls" => []}]
               },
               %{client_id: "local"}
             )

    assert assistant_tool_error.code == "unsupported_parameter"

    assert {:error, media_error} =
             OpenAIMapping.parse_chat_request(
               %{
                 "model" => "local",
                 "messages" => [
                   %{
                     "role" => "user",
                     "content" => [%{"type" => "image_url", "image_url" => %{}}]
                   }
                 ]
               },
               %{client_id: "local"}
             )

    assert media_error.code == "unsupported_content_part"

    assert {:error, model_error} =
             OpenAIMapping.parse_chat_request(
               %{"model" => "missing", "messages" => [%{"role" => "user", "content" => "hello"}]},
               %{client_id: "local"}
             )

    assert model_error.code == "model_not_enabled"
  end

  test "ACP stdio treats session metadata and permission responses as non-authority" do
    assert_eval_group!(:acp)

    enable_acp_stdio!()

    {:ok, [init], state} =
      AcpServer.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 0,
          "method" => "initialize",
          "params" => %{"protocolVersion" => 1, "clientInfo" => %{"name" => "zed"}}
        },
        AcpServer.new_state()
      )

    assert init["result"]["agentCapabilities"]["promptCapabilities"] == %{}
    refute Map.has_key?(init["result"]["agentCapabilities"], "mcpCapabilities")

    {:ok, [rejected], state} =
      AcpServer.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "session/new",
          "params" => %{"mcpServers" => [%{"name" => "filesystem", "command" => "mcp"}]}
        },
        state
      )

    assert rejected["error"]["data"]["code"] == "mcpservers_no_authority"

    {:ok, [created], state} =
      AcpServer.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "session/new",
          "params" => %{"cwd" => "/tmp/project", "mcpServers" => []}
        },
        state
      )

    session_id = created["result"]["sessionId"]

    {:ok, [content_rejected], _state} =
      AcpServer.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => session_id,
            "prompt" => [
              %{"type" => "resource_link", "uri" => "file:///tmp/a.ex", "name" => "a.ex"}
            ]
          }
        },
        state
      )

    assert content_rejected["error"]["data"]["code"] == "unsupported_content_block"
    refute_received {:runtime_request, _request}

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, _request ->
        {:ok,
         %{
           message: "Approval required.",
           status: :needs_confirmation,
           approval_handoff: %{confirmation_id: "conf_v051_acp"},
           actions: []
         }}
      end
    )

    {:ok, [_update, permission_request, response], state} =
      AcpServer.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => session_id,
            "prompt" => [%{"type" => "text", "text" => "Do gated work"}]
          }
        },
        state
      )

    assert permission_request["method"] == "session/request_permission"
    assert response["result"]["allbertStatus"] == "confirmation_pending"

    {:ok, [], _state} =
      AcpServer.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => permission_request["id"],
          "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "acknowledge"}}
        },
        state
      )

    assert {:ok, pending} =
             ResultReadback.get_for_client(
               response["result"]["allbertPublicCallId"],
               "acp_stdio",
               "zed"
             )

    assert pending.status == :pending
    refute Map.has_key?(pending, :result)
  end

  defp assert_eval_group!(group) do
    @eval_groups
    |> Keyword.fetch!(group)
    |> Enum.each(&assert_eval!/1)
  end

  defp assert_eval!(id), do: EvalInventory.row!(id)

  defp enable_mcp_stdio! do
    assert {:ok, _setting} = Settings.put("mcp_server.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("mcp_server.stdio.enabled", true, %{audit?: false})
  end

  defp enable_mcp_http! do
    assert {:ok, _setting} = Settings.put("mcp_server.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp_server.streamable_http.enabled", true, %{audit?: false})
  end

  defp enable_acp_stdio! do
    assert {:ok, _setting} = Settings.put("acp_server.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("acp_server.stdio.enabled", true, %{audit?: false})
  end

  defp allow_tools!(tools) do
    assert {:ok, _setting} = Settings.put("mcp_server.tools_enabled", tools, %{audit?: false})
  end

  defp allow_namespaces!(namespaces) do
    assert {:ok, _setting} =
             Settings.put("mcp_server.memory_namespaces_enabled", namespaces, %{audit?: false})
  end

  defp set_rate_limit!(client_id, rate_limit) do
    {:ok, clients} = Settings.get("mcp_server.clients")
    entry = Map.fetch!(clients, client_id)
    updated = Map.put(clients, client_id, Map.put(entry, "rate_limit", rate_limit))

    assert {:ok, _setting} = Settings.put("mcp_server.clients", updated, %{audit?: false})
  end

  defp context, do: %{actor: "test", channel: "test", audit?: false}

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
