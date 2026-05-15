defmodule Mix.Tasks.Allbert.AppsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias Mix.Tasks.Allbert.Apps, as: AppsTask
  alias Mix.Tasks.Allbert.ValidateApp, as: ValidateAppTask

  setup do
    ensure_stocksage_app!()

    on_exit(fn ->
      Mix.Task.reenable("allbert.apps")
      Mix.Task.reenable("allbert.validate_app")
    end)
  end

  test "lists and shows registered apps through registered actions" do
    list_output =
      capture_io(fn ->
        assert :ok = AppsTask.run(["list"])
      end)

    assert list_output =~ "Registered apps:"
    assert list_output =~ "allbert Allbert"
    assert list_output =~ "stocksage StockSage"
    refute list_output =~ "child_pid"

    show_output =
      capture_io(fn ->
        assert :ok = AppsTask.run(["show", "allbert"])
      end)

    assert show_output =~ "App: allbert"
    assert show_output =~ "Display name: Allbert"
    assert show_output =~ "Actions: (none)"
    assert show_output =~ "Skill paths: (none)"
    assert show_output =~ "Surface provider surfaces: agent:/agent"
    refute show_output =~ "chat-root"
  end

  test "validate checks a compiled module without registering another app" do
    before_count = length(AppRegistry.registered_apps())

    output =
      capture_io(fn ->
        assert :ok = AppsTask.run(["validate", "AllbertAssist.App.CoreApp"])
      end)

    assert output =~ "Validation: ok"
    assert output =~ "App: allbert"
    assert output =~ "Provider surfaces: agent:/agent"
    assert length(AppRegistry.registered_apps()) == before_count
  end

  test "standalone validate_app task prints v0.18 contract summary" do
    output =
      capture_io(fn ->
        assert :ok = ValidateAppTask.run(["AllbertAssist.App.CoreApp"])
      end)

    assert output =~ "Validation: ok"
    assert output =~ "app_id: allbert"
    assert output =~ "provider_surfaces: :agent:/agent"
    refute output =~ "chat-root"
  end

  test "unknown app and unknown module fail cleanly without creating atoms" do
    assert_raise Mix.Error, ~r/App not found: missing_app/, fn ->
      capture_io(fn ->
        AppsTask.run(["show", "missing_app"])
      end)
    end

    unknown = "AllbertAssist.App.Unknown#{System.unique_integer([:positive])}"
    atom_name = "Elixir." <> unknown

    assert_raise Mix.Error, ~r/unknown_module/, fn ->
      capture_io(fn ->
        AppsTask.run(["validate", unknown])
      end)
    end

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(atom_name)
    end
  end

  defp ensure_stocksage_app! do
    case AppRegistry.lookup(:stocksage) do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        PluginRegistry.register_module(StockSage.Plugin)
        assert {:ok, :stocksage} = AppRegistry.register(StockSage.App)
        on_exit(fn -> AppRegistry.unregister(:stocksage) end)
    end
  end
end
