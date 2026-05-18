defmodule AllbertAssist.Workspace.CatalogTest do
  use ExUnit.Case, async: true

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

  test "renderer dispatch is present as an M2 stub" do
    assert {:error, :renderer_not_implemented} = Catalog.component_renderer(:workspace)
    assert {:error, :unknown_component} = Catalog.component_renderer(:invented)
  end
end
