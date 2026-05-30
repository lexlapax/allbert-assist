defmodule AllbertAssist.Actions.McpConnectActionsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Mcp.ServerTrust
  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Store, as: SettingsStore
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.ToolCandidate

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-mcp-connect-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "connect creates consent first and only approval writes server config plus trust record" do
    {:ok, candidate} = persist_candidate(McpRegistryFixtures.official_secret_stdio_server())
    context = %{actor: "operator", channel: :test}

    assert {:ok, pending} =
             Runner.run("mcp_server_connect", %{candidate_id: candidate.id}, context)

    assert pending.status == :needs_confirmation
    assert pending.server_id == "io_github_acme_weather_secret"

    assert pending.connection.exact_command == %{
             command: "npx",
             args: ["-y", "@acme/weather-secret@2.0.0"]
           }

    assert [
             %{
               name: "WEATHER_API_KEY",
               ref: "secret://mcp/io_github_acme_weather_secret/weather_api_key"
             }
           ] = pending.connection.required_secret_refs

    refute configured_server("io_github_acme_weather_secret")

    assert {:ok, denied} =
             Runner.run(
               "deny_confirmation",
               %{id: pending.confirmation_id, reason: "not now"},
               context
             )

    assert denied.status == :completed
    refute configured_server("io_github_acme_weather_secret")

    assert {:ok, pending_again} =
             Runner.run("mcp_server_connect", %{candidate_id: candidate.id}, context)

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending_again.confirmation_id, reason: "approved"},
               context
             )

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"
    assert get_in(approved.confirmation, ["operator_resolution", "target_resumed?"])

    assert %{
             "enabled" => false,
             "transport" => "stdio",
             "command" => "npx",
             "args" => ["-y", "@acme/weather-secret@2.0.0"],
             "env" => %{
               "WEATHER_API_KEY" => "secret://mcp/io_github_acme_weather_secret/weather_api_key"
             }
           } = configured_server("io_github_acme_weather_secret")

    assert {:ok, trust_record} = ServerTrust.get("io_github_acme_weather_secret")
    assert trust_record.candidate_id == candidate.id
    assert trust_record.trust_status == "trusted"
    assert trust_record.transport == "stdio"
  end

  test "approved enabled connection lets doctor detect tool-definition rug pull" do
    {:ok, candidate} = persist_candidate(McpRegistryFixtures.official_shell_risk_server())
    context = %{actor: "operator", channel: :test}

    assert {:ok, pending} =
             Runner.run(
               "mcp_server_connect",
               %{candidate_id: candidate.id, server_id: "shell_risk", enable_on_connect: true},
               context
             )

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "approved"},
               context
             )

    assert get_in(approved.confirmation, ["operator_resolution", "target_status"]) == "completed"
    assert configured_server("shell_risk")["enabled"] == true
    configure_external()
    stub_changed_tools()

    assert {:ok, doctor} =
             Runner.run(
               "mcp_doctor_server",
               %{server_id: "shell_risk"},
               %{actor: "operator", channel: :test, mcp: %{req_plug: {Req.Test, __MODULE__}}}
             )

    assert doctor.status == :completed
    assert doctor.doctor.trust_baseline_ok == false
    assert Enum.any?(doctor.diagnostics, &(&1.code == :tool_definition_changed))
  end

  test "connect fails closed for missing candidate manifest" do
    {:ok, candidate} =
      ToolCandidate.normalize(%{
        id: "remote_mcp:official:empty",
        name: "empty",
        description: "empty",
        source: :remote_mcp,
        provenance: %{provider: :official, remote_server_id: "empty"}
      })

    assert {:ok, _record} = Discovery.upsert_candidate(candidate, %{registry_record: %{}})

    assert {:ok, response} =
             Runner.run("mcp_server_connect", %{candidate_id: candidate.id}, %{
               actor: "operator",
               channel: :test
             })

    assert response.status == :failed
    assert response.error == :missing_manifest
    refute response[:confirmation_id]
  end

  defp persist_candidate(manifest) do
    {:ok, candidate} =
      ToolCandidate.normalize(%{
        id: "remote_mcp:official:#{manifest["name"]}",
        name: manifest["name"],
        description: manifest["description"],
        source: :remote_mcp,
        provenance: %{
          provider: :official,
          remote_server_id: manifest["name"],
          repository_url: get_in(manifest, ["repository", "url"])
        }
      })

    assert {:ok, _record} = Discovery.upsert_candidate(candidate, %{registry_record: manifest})

    assert {:ok, report} =
             Discovery.evaluate_server(manifest, %{
               candidate_id: candidate.id,
               provider: "official",
               probe?: false
             })

    assert {:ok, _report_record} = Discovery.upsert_evaluation_report(candidate.id, report)
    {:ok, candidate}
  end

  defp configured_server(server_id) do
    {:ok, settings, _user_settings} = SettingsStore.resolved_settings()
    get_in(settings, ["mcp", "servers", server_id])
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["server.example"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/mcp"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_methods", ["POST"], %{audit?: false})
  end

  defp stub_changed_tools do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "initialize" ->
            %{"protocolVersion" => "2025-03-26", "capabilities" => %{}}

          "tools/list" ->
            %{
              "tools" => [
                %{"name" => "changed_tool", "description" => "Changed.", "inputSchema" => %{}}
              ]
            }

          "resources/list" ->
            %{"resources" => []}
        end

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    end)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
