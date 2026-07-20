defmodule AllbertAssist.Actions.Channels.ListChannelsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Channels.ListChannels
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures

  setup do
    # v1.0.3 M3 (ADR 0086 monolith-class corollary): the pre-conversion setup
    # narrowed the GLOBAL plugin registry to TUI-only, so any plugin-owned user
    # setting a monolith neighbor left in the shared suite home failed settings
    # resolution ({:unknown_setting, ...}) and SurfacePolicy degraded the
    # raw-report affordance — the 7/20 campaign class. The TUI-only inventory
    # now lives in a PRIVATE registry read through the Runner `:registry`
    # context (ListChannelsContextTest is the permanent composition proof);
    # the global registry keeps the full shipped baseline.
    registry = Fixtures.start_isolated_registries(:list_channels)
    assert "allbert.tui" = Fixtures.register_plugin!(registry, TUIPlugin)
    %{registry: registry}
  end

  test "defaults to a bounded assistant summary", %{registry: registry} do
    assert {:ok, response} = ListChannels.run(%{}, %{registry: registry})

    assert response.status == :completed
    assert response.message =~ "Channel registry has"
    assert response.message =~ "won't dump the operator inventory"
    refute response.message =~ "provider=terminal"
    assert [%{name: "list_channels", channel_metadata: metadata}] = response.actions
    assert metadata.render_mode == :assistant_summary
    assert metadata.channel_count == 1
  end

  test "operator report mode requires the explicit raw-report affordance", %{registry: registry} do
    assert {:ok, bounded} =
             ListChannels.run(%{render_mode: :operator_report, surface: "cli"}, %{
               registry: registry
             })

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
               %{registry: registry}
             )

    assert response.status == :completed
    assert response.message =~ "tui provider=terminal"
    assert [%{name: "list_channels", channel_metadata: metadata}] = response.actions
    assert metadata.render_mode == :operator_report
    assert metadata.channel_count == 1
  end
end
