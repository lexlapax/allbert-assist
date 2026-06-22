defmodule AllbertAssist.TestSupport.ProviderPreconditions do
  @moduledoc false

  import ExUnit.Assertions

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Schema

  def ensure_stocksage_descriptors! do
    :ok = AllbertAssist.StockSageRegistryCase.setup()
    assert intent_descriptors_present?(:stocksage, ["run_analysis"])
  end

  def ensure_notes_files_descriptors! do
    ensure_notes_files_plugin!()

    unless intent_descriptors_present?(:notes_files, ["write_note", "read_note"]) do
      AppRegistry.unregister(:notes_files)
      assert {:ok, :notes_files} = AppRegistry.register(AllbertNotesFiles.App)
    end

    assert intent_descriptors_present?(:notes_files, ["write_note", "read_note"])
  end

  def ensure_browser_descriptors! do
    ensure_browser_plugin!()

    unless intent_descriptors_present?(:allbert_browser, ["browser_research_handoff"]) do
      AppRegistry.unregister(:allbert_browser)
      assert {:ok, :allbert_browser} = AppRegistry.register(AllbertBrowser.App)
    end

    assert intent_descriptors_present?(:allbert_browser, ["browser_research_handoff"])
  end

  def ensure_tui_settings_schema! do
    case PluginRegistry.lookup("allbert.tui") do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        assert {:ok, "allbert.tui"} = PluginRegistry.register_module(TUIPlugin)
    end

    Fragments.clear_cache()
    assert Schema.known_key?("channels.tui.identity_map")
  end

  defp intent_descriptors_present?(app_id, action_names) do
    descriptor_actions =
      ExtensionsRegistry.registered_intent_descriptors()
      |> Enum.filter(&(&1.app_id == app_id))
      |> MapSet.new(& &1.action_name)

    MapSet.subset?(MapSet.new(action_names), descriptor_actions)
  end

  defp ensure_notes_files_plugin! do
    case PluginRegistry.lookup("allbert.notes_files") do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        assert {:ok, "allbert.notes_files"} =
                 PluginRegistry.register_module(AllbertNotesFiles.Plugin)
    end
  end

  defp ensure_browser_plugin! do
    case PluginRegistry.lookup("allbert.browser") do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        assert {:ok, "allbert.browser"} =
                 PluginRegistry.register_module(AllbertBrowser.Plugin)
    end
  end
end
