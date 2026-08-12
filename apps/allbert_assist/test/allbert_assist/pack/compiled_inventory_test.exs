defmodule AllbertAssist.Pack.CompiledInventoryTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Pack.CompiledInventory

  test "compiled action owners reconstruct the complete global order without a registry list" do
    assert {:ok, modules} = CompiledInventory.action_modules()

    assert length(modules) == 281
    assert Enum.map(modules, & &1.registry_order()) == Enum.to_list(1..281)
    assert Enum.all?(modules, &AllbertAssist.Action.allbert_action?/1)
    assert hd(modules) == AllbertAssist.Actions.Intent.DirectAnswer
    assert List.last(modules) == StockSage.Actions.Evidence.FetchFinancials
  end

  test "duplicate or missing owner tokens fail closed" do
    assert {:error, :invalid_action_registry_order} =
             CompiledInventory.validate_action_modules([
               AllbertAssist.Actions.Intent.DirectAnswer,
               AllbertAssist.Actions.Intent.ReadRecentMemory
             ])
  end

  test "compiled Plugin owners replace the shipped-module allowlist" do
    assert {:ok, plugins} = CompiledInventory.plugin_modules()

    assert plugins |> Map.keys() |> Enum.sort() == [
             "allbert.artifacts",
             "allbert.browser",
             "allbert.discord",
             "allbert.email",
             "allbert.matrix",
             "allbert.notes_files",
             "allbert.research",
             "allbert.signal",
             "allbert.slack",
             "allbert.telegram",
             "allbert.tui",
             "allbert.whatsapp",
             "stocksage"
           ]

    assert plugins["allbert.browser"] == AllbertBrowser.Plugin
    assert plugins["stocksage"] == StockSage.Plugin
  end

  # v1.4 M13.1. Implementing the behaviour used to be the whole test for product
  # membership, so the M0 ledger's subject -- which implements it in order to be
  # registered twice -- entered this inventory, and through it the production
  # `Plugin.Discovery.shipped_modules/0`. The subject declares `product?: false`
  # now, and this asserts the declaration is what the inventory honours rather
  # than the module's location or its lack of a manifest.
  test "a module that implements the behaviour but declares itself non-product is excluded" do
    subject = AllbertAssist.TestSupport.M0LedgerSubject

    assert AllbertAssist.Plugin in subject.__info__(:attributes)[:behaviour]
    refute subject.product?()

    assert {:ok, plugins} = CompiledInventory.plugin_modules()
    refute subject.plugin_id() in Map.keys(plugins)
    refute subject in Map.values(plugins)
  end

  test "App owners carry default and reserved declarations" do
    assert {:ok, [AllbertAssist.App.CoreApp]} = CompiledInventory.default_app_modules()

    assert {:ok,
            %{
              allbert: [AllbertAssist.App.CoreApp],
              stocksage: [StockSage.App]
            }} = CompiledInventory.reserved_app_owners()
  end
end
