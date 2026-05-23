defmodule AllbertAssist.Surface.CatalogTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Catalog
  alias AllbertAssist.Workspace

  @stocksage_components [:analysis_card, :agent_report_card, :parity_card, :debate_round_card]

  test "component membership is shared by Surface and Workspace catalog facades" do
    assert Catalog.known_components() == Surface.known_components()
    assert Catalog.known_components() == Workspace.Catalog.known_components()
    assert length(Catalog.known_components()) == 42
    assert :chat in Catalog.known_components()
    assert :debate_round_card in Catalog.known_components()
  end

  test "primitive and app component classification is centralized" do
    assert Catalog.primitive_component?(:section)
    assert Catalog.primitive_component?(:table)
    refute Catalog.primitive_component?(:analysis_card)

    for component <- @stocksage_components do
      assert Catalog.known_component?(component)
      assert Catalog.app_component?(component)
    end
  end

  test "renderer descriptors cover every known component" do
    for component <- Catalog.known_components() do
      assert Catalog.renderer_for(component) !=
               {:live_component, AllbertAssistWeb.Workspace.Components.Placeholder}
    end

    assert Catalog.renderer_for(:analysis_card) ==
             {:function_component, StockSageWeb.Components.Cards, :analysis_card}

    assert Catalog.renderer_module(:approval_card) ==
             AllbertAssistWeb.Workspace.Components.ApprovalCard

    assert Catalog.renderer_module(:analysis_card) == StockSageWeb.Components.Cards
  end

  test "app-declared catalog entries are known non-primitive components" do
    for %{component: component} <- StockSage.App.surface_catalog() do
      assert Catalog.known_component?(component)
      assert Catalog.app_component?(component)
    end
  end

  test "icons are catalog-owned" do
    assert Catalog.icon_for(:analysis_card) == "hero-chart-bar-micro"
    assert Catalog.icon_for(:invented) == "hero-squares-2x2-micro"
  end
end
