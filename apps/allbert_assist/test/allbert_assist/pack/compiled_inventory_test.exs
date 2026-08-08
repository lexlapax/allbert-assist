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

  test "App owners carry default and reserved declarations" do
    assert {:ok, [AllbertAssist.App.CoreApp]} = CompiledInventory.default_app_modules()

    assert {:ok,
            %{
              allbert: [AllbertAssist.App.CoreApp],
              stocksage: [StockSage.App]
            }} = CompiledInventory.reserved_app_owners()
  end
end
