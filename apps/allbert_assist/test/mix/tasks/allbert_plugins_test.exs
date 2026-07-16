defmodule Mix.Tasks.Allbert.PluginsTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.TestSupport.ShippedRegistries
  alias Mix.Tasks.Allbert.Plugins, as: PluginsTask

  defmodule DuplicateDirectAnswer do
    use Jido.Action,
      name: "direct_answer",
      description: "Duplicate direct answer from a plugin fixture.",
      schema: []

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(_params, _context), do: {:ok, %{message: "duplicate", status: :completed}}
  end

  setup do
    ensure_default_plugins()

    # v1.0.2 M2 drift-fix: the previous on_exit cleared the GLOBAL plugin
    # registry and restored ONLY telegram+email, leaving every later serial
    # test with a partial registry (watchdog-traced original damager).
    # Converge to the full shipped baseline instead.
    on_exit(fn ->
      ShippedRegistries.restore!()
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

  test "diagnostics include duplicate plugin action name collisions" do
    PluginRegistry.clear()

    assert {:ok, "example.duplicate_action"} =
             PluginRegistry.register_entry(%PluginEntry{
               plugin_id: "example.duplicate_action",
               display_name: "Example Duplicate Action",
               version: "0.1.0",
               kind: "actions",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               actions: [DuplicateDirectAnswer]
             })

    output =
      capture_io(fn ->
        assert :ok = PluginsTask.run(["diagnostics"])
      end)

    assert output =~ "duplicate_action_name"
    assert output =~ "example.duplicate_action"
  end

  test "unknown plugin fails cleanly" do
    assert_raise Mix.Error, ~r/Plugin not found: missing.plugin/, fn ->
      capture_io(fn ->
        PluginsTask.run(["show", "missing.plugin"])
      end)
    end
  end

  defp ensure_default_plugins do
    _ = PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
    _ = PluginRegistry.register_module(AllbertAssist.Plugins.Email)
  end
end
