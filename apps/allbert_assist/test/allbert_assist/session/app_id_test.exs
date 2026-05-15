defmodule AllbertAssist.Session.AppIdTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Session.AppId

  setup do
    registered? = AppRegistry.known_app_id?(:stocksage)
    ensure_stocksage_plugin!()

    unless registered? do
      assert {:ok, :stocksage} = AppRegistry.register(StockSage.App)
    end

    on_exit(fn ->
      unless registered?, do: AppRegistry.unregister(:stocksage)
    end)
  end

  defp ensure_stocksage_plugin! do
    case PluginRegistry.lookup("stocksage") do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        assert {:ok, "stocksage"} = PluginRegistry.register_module(StockSage.Plugin)
    end
  end

  test "normalizes nil aliases and known app ids through the registry" do
    assert {:ok, nil} = AppId.normalize(nil)
    assert {:ok, nil} = AppId.normalize("")
    assert {:ok, nil} = AppId.normalize("general")
    assert {:ok, :allbert} = AppId.normalize("allbert")
    assert {:ok, :allbert} = AppId.normalize(:allbert)
    assert {:ok, :stocksage} = AppId.normalize("stocksage")
    assert {:ok, :stocksage} = AppId.normalize(:stocksage)
  end

  test "rejects unknown strings and existing atoms that are not registered apps" do
    unknown = "__allbert_unknown_app_#{System.unique_integer([:positive])}__"
    assert {:error, :unknown_app} = AppId.normalize(unknown)

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unknown)
    end

    assert {:error, :unknown_app} = AppId.normalize(:not_registered_app_id_for_test)
  end

  test "labels only known registered atoms" do
    assert AppId.label(nil) == "none"
    assert AppId.label(:allbert) == "allbert"
    assert AppId.label(:stocksage) == "stocksage"
    refute AppRegistry.known_app_id?(:not_registered_app_id_for_test)
    assert AppId.label(:not_registered_app_id_for_test) == "unknown"
  end
end
