defmodule Mix.Tasks.Allbert.AppsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias Mix.Tasks.Allbert.Apps, as: AppsTask

  setup do
    on_exit(fn ->
      Mix.Task.reenable("allbert.apps")
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
    assert show_output =~ "Surfaces: (none)"
  end

  test "validate checks a compiled module without registering another app" do
    before_count = length(AppRegistry.registered_apps())

    output =
      capture_io(fn ->
        assert :ok = AppsTask.run(["validate", "AllbertAssist.App.CoreApp"])
      end)

    assert output =~ "Validation: ok"
    assert output =~ "App: allbert"
    assert length(AppRegistry.registered_apps()) == before_count
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
end
