defmodule Mix.Tasks.Allbert.PluginsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Allbert.Plugins, as: PluginsTask

  setup do
    on_exit(fn ->
      Mix.Task.reenable("allbert.plugins")
    end)
  end

  test "lists shipped plugins through the registered action boundary" do
    output =
      capture_io(fn ->
        assert :ok = PluginsTask.run(["list"])
      end)

    assert output =~ "Registered plugins:"
    assert output =~ "allbert.telegram"
    assert output =~ "allbert.email"
    assert output =~ "source=shipped"
    assert output =~ "channels=1"
    refute output =~ "bot_token"
    refute output =~ "password"
  end

  test "shows one plugin using safe normalized metadata" do
    output =
      capture_io(fn ->
        assert :ok = PluginsTask.run(["show", "allbert.telegram"])
      end)

    assert output =~ "Plugin: allbert.telegram"
    assert output =~ "Name: Allbert Telegram Channel"
    assert output =~ "Version: 0.17.0"
    assert output =~ "Source: shipped"
    assert output =~ "Channels: telegram"
    refute output =~ "bot_token_ref"
  end

  test "diagnostics command succeeds whether diagnostics are present or empty" do
    output =
      capture_io(fn ->
        assert :ok = PluginsTask.run(["diagnostics"])
      end)

    assert output =~ "Plugin diagnostics"
  end

  test "unknown plugin fails cleanly" do
    assert_raise Mix.Error, ~r/Plugin not found: missing.plugin/, fn ->
      capture_io(fn ->
        PluginsTask.run(["show", "missing.plugin"])
      end)
    end
  end
end
