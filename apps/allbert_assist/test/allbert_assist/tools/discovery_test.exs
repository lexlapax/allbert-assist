defmodule AllbertAssist.Tools.DiscoveryTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.Discovery.EvaluationReport
  alias AllbertAssist.Tools.ToolCandidate

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-tools-discovery-#{System.unique_integer([:positive])}"
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

  test "upserts candidate, evaluation report, suggestion, and baseline trust records" do
    {:ok, candidate} =
      ToolCandidate.normalize(%{
        id: "remote_mcp:official:weather",
        name: "io.github.acme/weather-mcp",
        description: "Weather forecast and alert tools.",
        source: :remote_mcp,
        provenance: %{
          provider: :official,
          remote_server_id: "io.github.acme/weather-mcp",
          repository_url: "https://github.com/acme/weather-mcp"
        },
        signals: %{kind: :mcp_registry_server}
      })

    manifest = McpRegistryFixtures.official_weather_server()

    assert {:ok, record} = Discovery.upsert_candidate(candidate, %{registry_record: manifest})
    assert record.usable_now == false
    assert record.requires == "connect_confirmation"
    assert record.registry_record["name"] == "io.github.acme/weather-mcp"

    assert {:ok, report} =
             Discovery.evaluate_server(manifest, %{
               candidate_id: candidate.id,
               provider: "official",
               probe?: false
             })

    assert report.provenance_level == "registry_with_source"
    assert report.health_status == "not_probed"
    assert report.metadata_authority == "descriptive_metadata_only"
    assert byte_size(report.tool_definition_hash) == 64

    assert {:ok, report_record} = Discovery.upsert_evaluation_report(candidate.id, report)
    assert report_record.tool_definition_hash == report.tool_definition_hash

    assert {:ok, _suggestion} =
             Discovery.upsert_suggestion(
               candidate.id,
               ToolCandidate.to_map(candidate),
               Discovery.evaluation_to_map(report)
             )

    assert [
             %{
               candidate_id: "remote_mcp:official:weather",
               provenance: "discovery",
               status: "pending",
               candidate_snapshot: %{"name" => "io.github.acme/weather-mcp"},
               updated_at: updated_at
             }
           ] = Discovery.list_suggestions()

    assert is_binary(updated_at)
    assert [] = Discovery.list_suggestions(status: "dismissed")

    assert {:ok, _baseline} = Discovery.upsert_baseline_trust_record(candidate.id, report)

    assert %EvaluationReport{} = Repo.get(EvaluationReport, "eval:#{candidate.id}")
  end

  test "self-improvement suggestions validate, persist, expire, and accept idempotently" do
    assert {:ok, _resolved} =
             Settings.put("self_improvement.suggestions.max_open", 2, %{audit?: false})

    assert {:ok, suggestion} =
             Discovery.upsert_self_improvement_suggestion(%{
               id: "suggestion:self_improvement:trace-skill",
               suggestion_type: "trace_to_skill",
               summary: "Repeated release-plan trace could become a skill.",
               evidence_refs: [%{pattern_type: :repeated_prompt, path: "traces/one.md"}],
               proposed_draft_kind: "skill",
               provenance: %{source: :trace_index, pattern_id: "pattern-1"}
             })

    assert suggestion.candidate_id == nil
    assert suggestion.provenance == "self_improvement"
    assert suggestion.expires_at

    assert [
             %{
               id: "suggestion:self_improvement:trace-skill",
               candidate_id: nil,
               provenance: "self_improvement",
               suggestion_type: "trace_to_skill",
               metadata: %{
                 "summary" => "Repeated release-plan trace could become a skill.",
                 "proposed_draft_kind" => "skill",
                 "evidence_refs" => [
                   %{"pattern_type" => "repeated_prompt", "path" => "traces/one.md"}
                 ],
                 "provenance" => %{"source" => "trace_index", "pattern_id" => "pattern-1"}
               }
             }
           ] = Discovery.list_suggestions(status: "pending", provenance: "self_improvement")

    assert {:error, {:invalid_suggestion_type, "unknown_kind"}} =
             Discovery.upsert_self_improvement_suggestion(%{
               suggestion_type: "unknown_kind",
               summary: "Invalid kind.",
               proposed_draft_kind: "skill"
             })

    assert {:ok, _suggestion} =
             Discovery.upsert_self_improvement_suggestion(%{
               id: "suggestion:self_improvement:memory",
               suggestion_type: "memory_update",
               summary: "Repeated correction should update memory.",
               evidence_refs: [],
               proposed_draft_kind: "memory_update"
             })

    assert {:error, {:max_open_suggestions, 2}} =
             Discovery.upsert_self_improvement_suggestion(%{
               id: "suggestion:self_improvement:workflow",
               suggestion_type: "trace_to_workflow",
               summary: "Repeated steps could become a workflow.",
               evidence_refs: [],
               proposed_draft_kind: "workflow"
             })

    assert {:ok, accepted} = Discovery.accept_suggestion(suggestion.id, "draft-skill-1")
    assert accepted.status == "accepted"
    assert accepted.draft_id == "draft-skill-1"

    assert {:ok, accepted_again} = Discovery.accept_suggestion(suggestion.id, "draft-skill-2")
    assert accepted_again.draft_id == "draft-skill-1"

    assert {:ok, _expired} =
             Discovery.upsert_self_improvement_suggestion(%{
               id: "suggestion:self_improvement:expired",
               suggestion_type: "memory_promotion",
               summary: "Expired suggestion.",
               evidence_refs: [],
               proposed_draft_kind: "memory_promotion",
               expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
             })

    refute Enum.any?(
             Discovery.list_suggestions(status: "pending", provenance: "self_improvement"),
             &(&1.id == "suggestion:self_improvement:expired")
           )

    assert Enum.any?(
             Discovery.list_suggestions(status: "expired", provenance: "self_improvement"),
             &(&1.id == "suggestion:self_improvement:expired")
           )
  end

  test "v0.47b handoff suggestion kinds are self-improvement only" do
    for {type, kind} <- [
          {"template_backed", "template_backed"},
          {"marketplace_backed", "marketplace_backed"},
          {"delegate_plugin_request", "delegate_plugin_request"},
          {"capability_gap", "capability_gap"},
          {"objective", "objective"}
        ] do
      assert {:ok, suggestion} =
               Discovery.upsert_self_improvement_suggestion(%{
                 id: "suggestion:self_improvement:#{type}",
                 suggestion_type: type,
                 summary: "#{type} suggestion remains advisory.",
                 evidence_refs: [%{source: "test"}],
                 proposed_draft_kind: kind
               })

      assert suggestion.candidate_id == nil
      assert suggestion.provenance == "self_improvement"
      assert suggestion.suggestion_type == type
      assert suggestion.metadata["proposed_draft_kind"] == kind
    end
  end

  test "evaluation flags dangerous command metadata and runs bounded health probe" do
    configure_external("server.example", "/mcp")

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    manifest = McpRegistryFixtures.official_shell_risk_server()

    assert {:ok, report} =
             Discovery.evaluate_server(manifest, %{
               provider: "official",
               context: %{external: %{req_plug: {Req.Test, __MODULE__}}},
               probe?: true
             })

    assert report.health_status == "reachable"
    assert Enum.any?(report.dangerous_command_flags, &(&1.reason == "remote_script_pipe"))

    assert Enum.any?(
             report.dangerous_command_flags,
             &(&1.reason == "destructive_recursive_remove")
           )

    assert {:ok, second_report} =
             Discovery.evaluate_server(manifest, %{
               provider: "official",
               probe?: false
             })

    assert second_report.tool_definition_hash == report.tool_definition_hash
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
