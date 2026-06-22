defmodule AllbertAssist.Tools.FinderTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  @operator_action_names [
    "operator_status",
    "operator_confirmations",
    "operator_events",
    "operator_channels",
    "operator_setting_get"
  ]

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Tools.Finder
  alias AllbertAssist.Tools.Source.Local
  alias AllbertAssist.Tools.ToolCandidate

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-tools-finder-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    {:ok, _log} = Agent.start(fn -> [] end, name: __MODULE__.CallLog)

    on_exit(fn ->
      if Process.whereis(__MODULE__.CallLog), do: safe_stop_call_log()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "local source finds registered actions and built-in skills without MCP transport" do
    assert {:ok, settings_candidates} =
             Local.search("settings", %{context: %{include_configured_mcp?: false}})

    assert Enum.any?(
             settings_candidates,
             &match?(%{source: :local_action, name: "list_settings"}, &1)
           )

    assert Enum.all?(settings_candidates, & &1.usable_now?)
    assert Enum.all?(settings_candidates, &(&1.requires == :none))

    assert {:ok, memory_candidates} =
             Local.search("append memory", %{context: %{include_configured_mcp?: false}})

    assert Enum.any?(
             memory_candidates,
             &match?(%{source: :local_skill, name: "append-memory"}, &1)
           )

    assert Agent.get(__MODULE__.CallLog, & &1) == []
  end

  test "local source excludes internal operator inspection actions from suggestions" do
    assert {:ok, candidates} =
             Local.search("operator", %{context: %{include_configured_mcp?: false}, limit: 100})

    candidate_names = candidates |> Enum.map(& &1.name) |> MapSet.new()

    for action_name <- @operator_action_names do
      refute MapSet.member?(candidate_names, action_name)
    end

    local_actions = Enum.filter(candidates, &(&1.source == :local_action))
    assert Enum.all?(local_actions, &(Map.get(&1.signals, :exposure) == :agent))
  end

  test "local source degrades when skill registry fails" do
    context = %{
      include_configured_mcp?: false,
      skills_registry: __MODULE__.FailingSkillsRegistry
    }

    assert {:ok, %{candidates: candidates, diagnostics: [diagnostic]}} =
             Local.search_with_diagnostics("settings", %{context: context})

    assert Enum.any?(candidates, &match?(%{source: :local_action, name: "list_settings"}, &1))
    assert diagnostic.source == :local_skill
    assert diagnostic.status == :degraded
    assert diagnostic.reason =~ "registry_unavailable"
  end

  test "local source includes tools from configured enabled MCP servers" do
    configure_external()
    configure_http_server()
    stub_http_mcp()

    context = %{actor: "local", channel: :test, mcp: %{req_plug: {Req.Test, __MODULE__}}}

    assert {:ok, candidates} = Local.search("calendar", %{context: context})

    assert [%ToolCandidate{source: :configured_mcp} = candidate] =
             Enum.filter(candidates, &(&1.source == :configured_mcp))

    assert candidate.name == "demo:calendar_events"
    assert candidate.description == "Read calendar events."
    assert candidate.usable_now?
    assert candidate.requires == :none
    assert candidate.provenance.server_id == "demo"
    assert Agent.get(__MODULE__.CallLog, & &1) == ["initialize", "tools/list"]
  end

  test "find_tools merges and dedupes enabled source results" do
    assert {:ok, %{candidates: candidates, diagnostics: []}} =
             Finder.find("duplicate", %{
               sources: [__MODULE__.DuplicateSourceA, __MODULE__.DuplicateSourceB]
             })

    assert [%ToolCandidate{name: "duplicate_tool"}] = candidates
  end

  test "find_tools keeps local candidates when remote registry source is unreachable" do
    configure_discovery()
    configure_registry_external()

    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))

    context = %{actor: "local", channel: :test, external: %{req_plug: {Req.Test, __MODULE__}}}

    assert {:ok, %{candidates: candidates, diagnostics: [diagnostic]}} =
             Finder.find("settings", %{context: context, limit: 10})

    assert Enum.any?(candidates, &match?(%{source: :local_action, name: "list_settings"}, &1))
    assert diagnostic.source == :official
    assert diagnostic.status == :degraded
  end

  defmodule DuplicateSourceA do
    @behaviour AllbertAssist.Tools.SourcePort

    alias AllbertAssist.Tools.ToolCandidate

    def source_id, do: :duplicate_a

    def search(_query, _opts) do
      ToolCandidate.normalize(%{
        id: "duplicate:a",
        name: "duplicate_tool",
        description: "duplicate candidate",
        source: :local_action
      })
      |> then(fn {:ok, candidate} -> {:ok, [candidate]} end)
    end
  end

  defmodule DuplicateSourceB do
    @behaviour AllbertAssist.Tools.SourcePort

    alias AllbertAssist.Tools.ToolCandidate

    def source_id, do: :duplicate_b

    def search(_query, _opts) do
      ToolCandidate.normalize(%{
        id: "duplicate:b",
        name: "duplicate_tool",
        description: "same source/name loses in dedupe",
        source: :local_action
      })
      |> then(fn {:ok, candidate} -> {:ok, [candidate]} end)
    end
  end

  defmodule FailingSkillsRegistry do
    def list(_context), do: {:error, :registry_unavailable}
  end

  defp configure_http_server do
    assert {:ok, _setting} = Settings.put("mcp.servers.demo.enabled", false, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.demo.transport", "streamable_http", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.demo.base_url", "https://example.com/mcp", %{
               audit?: false
             })

    assert {:ok, _setting} = Settings.put("mcp.servers.demo.enabled", true, %{audit?: false})
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/mcp"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_methods", ["POST"], %{audit?: false})
  end

  defp configure_discovery do
    assert {:ok, _setting} = Settings.put("mcp.discovery.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.discovery.sources.official.enabled", true, %{audit?: false})
  end

  defp configure_registry_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "external_services.allowed_hosts",
               ["registry.modelcontextprotocol.io"],
               %{
                 audit?: false
               }
             )

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/v0.1/servers"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_methods", ["GET"], %{audit?: false})
  end

  defp stub_http_mcp do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(__MODULE__.CallLog, &(&1 ++ [request["method"]]))

      result =
        case request["method"] do
          "initialize" ->
            %{"protocolVersion" => "2025-03-26", "capabilities" => %{}}

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => "calendar_events",
                  "description" => "Read calendar events.",
                  "inputSchema" => %{}
                }
              ]
            }
        end

      response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})

      Plug.Conn.send_resp(conn, 200, response)
    end)
  end

  defp safe_stop_call_log do
    Agent.stop(__MODULE__.CallLog)
  catch
    :exit, _reason -> :ok
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
