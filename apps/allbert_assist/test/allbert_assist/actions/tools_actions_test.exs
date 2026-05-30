defmodule AllbertAssist.Actions.ToolsActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-tools-actions-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "find_local_tools returns usable local candidates" do
    context = %{actor: "local", channel: :test, include_configured_mcp?: false}

    assert {:ok, response} = Runner.run("find_local_tools", %{query: "settings"}, context)

    assert response.status == :completed
    assert response.permission_decision.decision == :allowed

    assert Enum.any?(
             response.candidates,
             &(&1.source == :local_action and &1.name == "list_settings")
           )

    assert Enum.all?(response.candidates, & &1.usable_now?)
    assert Enum.all?(response.candidates, &(&1.requires == :none))
  end

  test "find_tools orchestrates the local source in M2" do
    context = %{actor: "local", channel: :test, include_configured_mcp?: false}

    assert {:ok, response} = Runner.run("find_tools", %{query: "settings"}, context)

    assert response.status == :completed
    assert response.diagnostics == []

    assert Enum.any?(
             response.candidates,
             &(&1.source == :local_action and &1.name == "list_settings")
           )
  end

  test "tool discovery actions are registered as internal MCP discovery capabilities" do
    assert {:ok, find_local_tools} = Registry.capability("find_local_tools")
    assert find_local_tools.permission == :read_only
    assert find_local_tools.exposure == :internal
    assert find_local_tools.execution_mode == :mcp_discovery

    assert {:ok, find_tools} = Registry.capability("find_tools")
    assert find_tools.permission == :read_only
    assert find_tools.exposure == :internal
    assert find_tools.execution_mode == :mcp_discovery
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
