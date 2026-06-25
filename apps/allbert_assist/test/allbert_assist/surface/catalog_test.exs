defmodule AllbertAssist.Surface.CatalogTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Catalog
  alias AllbertAssist.Workspace

  @stocksage_components [:analysis_card, :agent_report_card, :parity_card, :debate_round_card]

  test "component membership is shared by Surface and Workspace catalog facades" do
    assert Catalog.known_components() == Surface.known_components()
    assert Catalog.known_components() == Workspace.Catalog.known_components()
    assert length(Catalog.known_components()) == 57
    assert :chat in Catalog.known_components()
    assert :workspace_shell in Catalog.known_components()
    assert :app_launcher in Catalog.known_components()
    assert :onboarding_panel in Catalog.known_components()
    assert :intents_panel in Catalog.known_components()
    assert :models_panel in Catalog.known_components()
    assert :surface_policy_panel in Catalog.known_components()
    assert :settings_panel in Catalog.known_components()
    assert :template_create_panel in Catalog.known_components()
    assert :plan_preview_panel in Catalog.known_components()
    assert :plan_run_progress_panel in Catalog.known_components()
    assert :mcp_effect_form in Catalog.known_components()
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

  test "workspace zones are catalog-owned" do
    assert Catalog.known_zones() == [
             :nav_apps,
             :context_rail,
             :canvas_panels,
             :utility_drawer,
             :ephemeral
           ]

    assert Surface.known_zones() == Catalog.known_zones()
    assert Catalog.known_zone?(:canvas_panels)
    refute Catalog.known_zone?(:invented_zone)
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
