defmodule AllbertAssist.Actions.Channels.ListChannelsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Channels.ListChannels
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin

  setup do
    original_plugins = PluginRegistry.registered_plugins()

    PluginRegistry.clear()
    assert {:ok, "allbert.tui"} = PluginRegistry.register_module(TUIPlugin)

    on_exit(fn ->
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
    end)

    :ok
  end

  test "defaults to a bounded assistant summary" do
    assert {:ok, response} = ListChannels.run(%{}, %{})

    assert response.status == :completed
    assert response.message =~ "Channel registry has"
    assert response.message =~ "won't dump the operator inventory"
    refute response.message =~ "provider=terminal"
    assert [%{name: "list_channels", channel_metadata: metadata}] = response.actions
    assert metadata.render_mode == :assistant_summary
    assert metadata.channel_count == 1
  end

  test "operator report mode renders the full channel inventory" do
    assert {:ok, response} = ListChannels.run(%{render_mode: :operator_report}, %{})

    assert response.status == :completed
    assert response.message =~ "tui provider=terminal"
    assert [%{name: "list_channels", channel_metadata: metadata}] = response.actions
    assert metadata.render_mode == :operator_report
    assert metadata.channel_count == 1
  end
end
