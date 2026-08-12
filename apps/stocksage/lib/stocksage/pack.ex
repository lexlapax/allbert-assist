defmodule StockSage.Pack do
  @moduledoc """
  Pack descriptor for the extracted StockSage app.

  The last two M13 extractions (with `AllbertArtifacts.Pack`) were held back
  because each shipped a LiveView the web router named directly, and Web depends
  on the residual, so Web naming a pack's module while the pack depended on Web
  for `use AllbertAssistWeb, :live_view` was a cycle no amount of path fixing
  removed. `AllbertAssist.Pack.WebSurface` breaks it: `StockSageWeb.AnalysisLive`
  now declares that behaviour instead, `surfaces/0` below contributes it to
  `AllbertAssistWeb.PackSurfaces`, and `AllbertAssistWeb.PackSurfaceLive` -- owned
  and routed by Web, naming no pack -- resolves and hosts it at runtime.

  `apps/0` and `actions/0` stay empty for the reason they do in every pack: the
  contributions come from the manifest at `priv/allbert_plugin.json`, and
  declaring them here as well would contribute them twice.
  """

  @behaviour AllbertAssist.Pack

  alias AllbertAssist.Pack.Descriptor

  @application_version Mix.Project.config()[:version]
  @empty_callbacks [
    :apps,
    :actions,
    :settings_migrations,
    :channels,
    :skill_roots,
    :home_roots,
    :jobs,
    :stores,
    :prompt_rules,
    :intent_descriptors,
    :cli_groups,
    :release_assets
  ]

  @impl true
  def descriptor do
    %Descriptor{
      schema_version: 1,
      # Deliberately NOT "stocksage". ADR 0098 section 9 keeps each legacy manifest
      # as an identity-equivalent deprecated alias of its pack, and every other
      # pack's two names differ by construction -- pack "allbert_notes_files"
      # against plugin "allbert.notes_files". StockSage is the one plugin whose id
      # carries no dotted prefix, so an app-named pack id would be byte-identical
      # to its plugin id and composition rejects the pair as duplicate_identity.
      id: "allbert_stocksage",
      application: :stocksage,
      application_version: @application_version,
      capability_tier: :native,
      provenance: %{source: :signed_release, component: "beam-stocksage"},
      # Continues the 100 spacing: kernel 0, residual 100, ... allbert_artifacts 1300.
      registry_order: 1400
    }
  end

  for callback <- @empty_callbacks do
    @impl true
    def unquote(callback)(), do: []
  end

  # The plugin already owned its schema through the `settings_schema/0`
  # callback in `StockSage.Plugin`; that literal list moved to
  # `StockSage.Settings.Fragment` and `StockSage.Plugin.settings_schema/0` now
  # returns `[]`. Declaring the schema in both places would produce the same
  # fragment id twice and fail composition with :duplicate_settings_fragment_id.
  @impl true
  def settings_fragments, do: [StockSage.SettingsFragment]

  @impl true
  def surfaces, do: [%{surface_id: "stocksage", module: StockSageWeb.AnalysisLive}]

  @impl true
  def test_lanes do
    [
      %{
        owner_id: :stocksage,
        application: :stocksage,
        cwd: "apps/stocksage",
        production_source_roots: ["apps/stocksage/lib"],
        test_roots: ["apps/stocksage/test"],
        test_support_roots: ["apps/stocksage/test/support"],
        allowed_primary_lanes: [
          :pure_async,
          :db_serial,
          :db_partition_safe,
          :app_env_serial,
          :home_fs_serial,
          :global_process_serial,
          :external_runtime_serial,
          :liveview_serial,
          :security_eval_serial
        ],
        aggregate_policy: :allbert_test_raw,
        target_resolver: {AllbertAssist.DevGates.GateTargetResolver, :resolve},
        historical_metrics_aliases: ["stocksage"]
      }
    ]
  end
end
