defmodule AllbertAssist.Actions.Channels.ListChannelsContextTest do
  use AllbertAssist.DataCase, async: false

  # v1.0.3 M3 permanent minimal-composition regression (ADR 0086 monolith-class
  # corollary; release.v103 step `v103_list_channels_context`).
  #
  # The retired campaign class (`ListChannelsTest` "operator report mode
  # requires the explicit raw-report affordance", 7/20 monolith seeds):
  # a monolith neighbor leaves a PLUGIN-OWNED user setting in the settings
  # root it shares with ListChannelsTest; ListChannelsTest's pre-conversion
  # setup then narrowed the GLOBAL plugin registry to TUI-only, so settings
  # resolution failed (`{:error, {:unknown_setting, "stocksage"}}`),
  # SurfacePolicy fell back to its degraded default, and the raw-report
  # affordance collapsed to an assistant summary. Reproduced OUTSIDE the
  # monolith red-first as a deterministic two-file composition (recorded in
  # the plan's M3 Build Progress entry): a neighbor that writes
  # `stocksage.bridge_enabled` into the shared suite home composed with the
  # pre-conversion ListChannelsTest fails on the exact campaign signature
  # (`mix test <neighbor> <list_channels_test> --seed 0`, exit 2).
  #
  # The fix is at the ownership root, never the symptom: ListChannels reads
  # travel the internal registry context (`ListChannels.run/2` forwards the
  # Runner `:registry` context-map key to `Channels.list_channels/1`), so the
  # test owns a PRIVATE TUI-only registry and the GLOBAL registry keeps the
  # full shipped baseline — under which any shipped-plugin residue key still
  # validates. This file composes both halves permanently: the neighbor's
  # residue is planted in an owned settings root, and the raw-report
  # affordance must survive it through the private context. Before the M3
  # conversion this file is RED (run/2 ignored `:registry`, so the private
  # TUI-only context leaked to the full global channel inventory).

  alias AllbertAssist.Actions.Channels.ListChannels
  alias AllbertAssist.Channels
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-list-channels-ctx-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      if original_paths_config do
        Application.put_env(:allbert_assist, Paths, original_paths_config)
      else
        Application.delete_env(:allbert_assist, Paths)
      end

      File.rm_rf!(home)
    end)

    # The neighbor's residue: a plugin-owned user setting left in the settings
    # root. The write validates because the GLOBAL registry carries the full
    # shipped baseline (the M3 convergence invariant); the same key is
    # `{:unknown_setting, "stocksage"}` under any narrowed global composition.
    assert {:ok, _resolved} =
             Settings.put("stocksage.bridge_enabled", false, %{
               actor: "m3_composition",
               audit?: false
             })

    registry = Fixtures.start_isolated_registries(:list_channels_ctx)
    assert "allbert.tui" = Fixtures.register_plugin!(registry, TUIPlugin)
    %{registry: registry}
  end

  test "neighbor residue composition: the raw-report affordance survives through the private registry context",
       %{registry: registry} do
    assert {:ok, bounded} =
             ListChannels.run(
               %{render_mode: :operator_report, surface: "cli"},
               %{registry: registry}
             )

    assert bounded.status == :completed
    assert bounded.message =~ "won't dump the operator inventory"
    assert [%{name: "list_channels", channel_metadata: bounded_metadata}] = bounded.actions
    assert bounded_metadata.render_mode == :assistant_summary
    assert bounded_metadata.channel_count == 1

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

  test "production default path reads the global registry unchanged", %{registry: _registry} do
    global_channels = Channels.list_channels()
    assert length(global_channels) > 1

    assert {:ok, response} = ListChannels.run(%{}, %{})

    assert response.status == :completed
    assert [%{name: "list_channels", channel_metadata: metadata}] = response.actions
    assert metadata.render_mode == :assistant_summary
    assert metadata.channel_count == length(global_channels)
  end
end
