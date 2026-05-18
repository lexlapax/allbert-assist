defmodule AllbertAssist.Workspace.CatalogTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Catalog

  test "known components returns the 42-component v0.26 allow-list" do
    components = Catalog.known_components()

    assert length(components) == 42
    assert Enum.uniq(components) == components

    assert Enum.all?(
             [
               :route,
               :chat,
               :timeline,
               :composer,
               :status_badge,
               :workspace,
               :canvas,
               :tile,
               :ephemeral_surface,
               :approval_card,
               :memory_review_card,
               :analysis_card,
               :debate_round_card
             ],
             &(&1 in components)
           )
  end

  test "workspace tree returns the v0.26 core /agent surface" do
    surface = Catalog.workspace_tree(user_id: "local", thread_id: "thread-1")

    assert surface.id == :agent
    assert surface.path == "/agent"
    assert surface.kind == :workspace
    assert surface.metadata.workspace == %{user_id: "local", thread_id: "thread-1"}

    assert [%Node{component: :workspace, children: children}] = surface.nodes
    assert Enum.any?(children, &match?(%Node{component: :chat}, &1))
    assert Enum.any?(children, &match?(%Node{component: :canvas}, &1))
    assert Enum.any?(children, &match?(%Node{component: :ephemeral_surface}, &1))
  end

  test "renderer dispatch is web-agnostic placeholder metadata" do
    assert {:ok, :placeholder} = Catalog.component_renderer(:workspace)
    assert {:error, :unknown_component} = Catalog.component_renderer(:invented)
  end
end
