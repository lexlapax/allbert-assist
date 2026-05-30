defmodule AllbertAssist.Workspace.DiscoverySuggestionsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.ToolCandidate
  alias AllbertAssist.Workspace.DiscoverySuggestions

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-discovery-suggestions-#{System.unique_integer([:positive])}"
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

  test "panel lists pending suggestions with a connect action and hides dismissed suggestions" do
    manifest = McpRegistryFixtures.official_weather_server()
    {:ok, pending_candidate} = persist_suggestion(manifest, "pending")

    {:ok, _dismissed_candidate} =
      persist_suggestion(McpRegistryFixtures.official_shell_risk_server(), "dismissed")

    surface = DiscoverySuggestions.surface(%{})

    assert surface.id == :core_discovery_suggestions_panel
    assert surface.metadata.visible_when == :operator_opened
    assert [%Node{children: children}] = surface.nodes

    assert Enum.any?(children, fn node ->
             node.component == :settings_card and
               node.props.external_id == pending_candidate.id
           end)

    assert Enum.any?(children, fn node ->
             node.component == :action_button and
               node.props.phx_click == "connect_discovery_candidate" and
               node.props.candidate_id == pending_candidate.id
           end)

    refute Enum.any?(children, fn node ->
             node.component == :settings_card and
               node.props.external_id == "remote_mcp:official:io.github.acme/shell-risk"
           end)
  end

  defp persist_suggestion(manifest, status) do
    {:ok, candidate} =
      ToolCandidate.normalize(%{
        id: "remote_mcp:official:#{manifest["name"]}",
        name: manifest["name"],
        description: manifest["description"],
        source: :remote_mcp,
        provenance: %{provider: :official, remote_server_id: manifest["name"]}
      })

    assert {:ok, _record} = Discovery.upsert_candidate(candidate, %{registry_record: manifest})

    assert {:ok, report} =
             Discovery.evaluate_server(manifest, %{
               candidate_id: candidate.id,
               provider: "official"
             })

    assert {:ok, _suggestion} =
             Discovery.upsert_suggestion(
               candidate.id,
               ToolCandidate.to_map(candidate),
               Discovery.evaluation_to_map(report),
               %{status: status}
             )

    {:ok, candidate}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
