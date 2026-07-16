defmodule AllbertAssist.Marketplace.SurfaceProviderTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Marketplace
  alias AllbertAssist.Marketplace.SurfaceProvider
  alias AllbertAssist.Paths
  alias AllbertAssist.Surface
  alias AllbertAssist.Workspace.Catalog, as: WorkspaceCatalog

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_home = System.get_env("ALLBERT_HOME")
    home = temp_path("home")

    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_env("ALLBERT_HOME", original_home)
      File.rm_rf!(home)
    end)

    {:ok, home: home, context: context()}
  end

  test "catalog panel groups entries and exposes kind-correct action affordances", %{
    context: context
  } do
    surface = SurfaceProvider.catalog_surface(context)

    assert surface.id == :marketplace_catalog_panel
    assert surface.metadata.visible_when == :operator_opened
    assert {:ok, validated} = Surface.validate_surface(surface)

    nodes = flatten(validated.nodes)
    assert node_with?(nodes, :panel, title: "Marketplace Catalog")
    assert node_with?(nodes, :section, title: "Skills")
    assert node_with?(nodes, :section, title: "Templates")
    assert node_with?(nodes, :section, title: "Plugin Index")

    assert entry_action_names(nodes, "allbert/research-helpers") == [
             "inspect_marketplace_entry",
             "verify_marketplace_bundle_hash",
             "install_marketplace_bundle"
           ]

    assert entry_action_names(nodes, "allbert/workspace-brief") == [
             "inspect_marketplace_entry",
             "verify_marketplace_bundle_hash",
             "install_marketplace_bundle"
           ]

    assert entry_action_names(nodes, "allbert/reviewed-plugin-sources") == [
             "inspect_marketplace_entry",
             "verify_marketplace_bundle_hash"
           ]

    assert Enum.all?(action_nodes(nodes), fn node ->
             [binding] = node.bindings
             binding.action_name == node.props.action_name and not is_nil(binding.permission)
           end)
  end

  test "installed skill entry switches install affordance to rollback", %{context: context} do
    assert {:ok, _result} = Marketplace.install_bundle("allbert/research-helpers")

    nodes =
      context
      |> SurfaceProvider.catalog_surface()
      |> Map.fetch!(:nodes)
      |> flatten()

    assert entry_action_names(nodes, "allbert/research-helpers") == [
             "inspect_marketplace_entry",
             "verify_marketplace_bundle_hash",
             "rollback_marketplace_install"
           ]
  end

  test "workspace catalog knows the marketplace destination and panel mapping", %{
    context: context
  } do
    assert Enum.any?(WorkspaceCatalog.known_destinations(), &(&1.id == "workspace:marketplace"))

    tree =
      WorkspaceCatalog.workspace_tree(
        user_id: "local",
        thread_id: "thread-marketplace",
        canvas_tiles: [],
        ephemeral_surfaces: [],
        workspace_badges: [],
        active_app: :allbert,
        canvas_destination: "workspace:marketplace",
        registered_apps: [%{app_id: :allbert, display_name: "Allbert"}],
        panel_surfaces: [SurfaceProvider.catalog_surface(context)],
        surface_catalogs: %{}
      )

    assert tree.id == :workspace
    assert tree.metadata.layout
    assert node_with?(flatten(tree.nodes), :panel, title: "Marketplace Catalog")
  end

  defp context do
    %{
      user_id: "local",
      operator_id: "local",
      thread_id: "thread-marketplace",
      session_id: "session-marketplace",
      active_app: :allbert,
      canvas_destination: "workspace:marketplace"
    }
  end

  defp action_nodes(nodes), do: Enum.filter(nodes, &(&1.component == :action_button))

  defp entry_action_names(nodes, entry_id) do
    nodes
    |> action_nodes()
    |> Enum.filter(&(&1.props.entry_id == entry_id))
    |> Enum.map(& &1.props.action_name)
  end

  defp node_with?(nodes, component, props) do
    Enum.any?(nodes, fn node ->
      node.component == component and
        Enum.all?(props, fn {key, value} -> Map.get(node.props, key) == value end)
    end)
  end

  defp flatten(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &flatten/1)
  defp flatten(%{children: children} = node), do: [node | flatten(children)]

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-marketplace-surface-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
