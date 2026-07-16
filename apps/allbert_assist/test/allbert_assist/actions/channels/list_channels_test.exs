defmodule AllbertAssist.Actions.Channels.ListChannelsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Channels.ListChannels
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin
  alias AllbertAssist.TestSupport.ShippedRegistries

  setup do
    PluginRegistry.clear()
    assert {:ok, "allbert.tui"} = PluginRegistry.register_module(TUIPlugin)

    on_exit(fn ->
      ShippedRegistries.restore!()
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

  test "operator report mode requires the explicit raw-report affordance" do
    assert {:ok, bounded} =
             ListChannels.run(%{render_mode: :operator_report, surface: "cli"}, %{})

    assert bounded.status == :completed
    assert bounded.message =~ "won't dump the operator inventory"
    refute bounded.message =~ "tui provider=terminal"
    assert [%{name: "list_channels", channel_metadata: bounded_metadata}] = bounded.actions
    assert bounded_metadata.render_mode == :assistant_summary

    assert {:ok, response} =
             ListChannels.run(
               %{
                 render_mode: :operator_report,
                 surface: "cli",
                 surface_policy_affordance: true
               },
               %{}
             )

    assert response.status == :completed
    assert response.message =~ "tui provider=terminal"
    assert [%{name: "list_channels", channel_metadata: metadata}] = response.actions
    assert metadata.render_mode == :operator_report
    assert metadata.channel_count == 1
  end
end
