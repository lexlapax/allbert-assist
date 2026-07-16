defmodule AllbertAssist.Tools.McpRegistrySourceTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.Discovery.BaselineTrustRecord
  alias AllbertAssist.Tools.Discovery.EvaluationReport
  alias AllbertAssist.Tools.Discovery.Suggestion
  alias AllbertAssist.Tools.Source.McpRegistry

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-mcp-registry-source-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "disabled discovery returns no remote candidates and performs no egress" do
    assert {:ok, %{candidates: [], diagnostics: []}} =
             McpRegistry.search_with_diagnostics("weather", %{
               context: %{external: %{req_plug: {Req.Test, __MODULE__}}}
             })
  end

  test "official registry results become inert remote candidates and persisted reports" do
    configure_discovery()
    configure_external("registry.modelcontextprotocol.io", "/v0.1/servers")
    stub_official(McpRegistryFixtures.official_response())

    assert {:ok, %{candidates: [candidate], diagnostics: []}} =
             McpRegistry.search_with_diagnostics("weather", %{
               context: %{external: %{req_plug: {Req.Test, __MODULE__}}},
               limit: 5
             })

    assert candidate.source == :remote_mcp
    assert candidate.usable_now? == false
    assert candidate.requires == :connect_confirmation
    assert candidate.provenance.provider == :official
    assert candidate.provenance.metadata_authority == "descriptive_metadata_only"

    assert {:ok, record} = Discovery.get_candidate(candidate.id)
    assert record.name == "io.github.acme/weather-mcp"
    assert Repo.get(EvaluationReport, "eval:#{candidate.id}")
    assert Repo.get(Suggestion, "suggestion:#{candidate.id}")
    assert Repo.get(BaselineTrustRecord, "baseline:#{candidate.id}")
  end

  test "missing PulseMCP secrets skip Pulse without failing official search" do
    configure_discovery()
    configure_missing_pulsemcp_refs()
    configure_external("registry.modelcontextprotocol.io", "/v0.1/servers")
    stub_official(McpRegistryFixtures.official_response())

    assert {:ok, %{candidates: [candidate], diagnostics: diagnostics}} =
             McpRegistry.search_with_diagnostics("weather", %{
               context: %{external: %{req_plug: {Req.Test, __MODULE__}}},
               limit: 5
             })

    assert candidate.provenance.provider == :official
    assert Enum.any?(diagnostics, &(&1.source == :pulsemcp and &1.status == :skipped))
  end

  test "unreachable registry source degrades instead of failing the search" do
    configure_discovery()
    configure_external("registry.modelcontextprotocol.io", "/v0.1/servers")

    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))

    assert {:ok, %{candidates: [], diagnostics: [diagnostic]}} =
             McpRegistry.search_with_diagnostics("weather", %{
               context: %{external: %{req_plug: {Req.Test, __MODULE__}}},
               limit: 5
             })

    assert diagnostic.source == :official
    assert diagnostic.status == :degraded
    assert diagnostic.reason =~ "timeout"
  end

  defp stub_official(response) do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, Jason.encode!(response))
    end)
  end

  defp configure_discovery do
    assert {:ok, _setting} = Settings.put("mcp.discovery.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.discovery.sources.official.enabled", true, %{audit?: false})
  end

  defp configure_missing_pulsemcp_refs do
    assert {:ok, _setting} =
             Settings.put(
               "mcp.discovery.sources.pulsemcp.api_key_ref",
               "secret://mcp/pulsemcp/api_key",
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put(
               "mcp.discovery.sources.pulsemcp.tenant_ref",
               "secret://mcp/pulsemcp/tenant",
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("mcp.discovery.sources.pulsemcp.enabled", true, %{audit?: false})
  end

  defp configure_external(host, path) do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", [host], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", [path], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_methods", ["GET"], %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
