defmodule AllbertArtifacts.Pack do
  @moduledoc """
  Pack descriptor for the extracted Artifacts Browser.

  The last two M13 extractions (with `StockSage.Pack`) were held back because
  each shipped a LiveView the web router named directly, and Web depends on the
  residual, so Web naming a pack's module while the pack depended on Web for
  `use AllbertAssistWeb, :live_view` was a cycle no amount of path fixing
  removed. `AllbertAssist.Pack.WebSurface` breaks it: `AllbertArtifactsWeb.ArtifactLive`
  now declares that behaviour instead, `surfaces/0` below contributes it to
  `AllbertAssistWeb.PackSurfaces`, and `AllbertAssistWeb.PackSurfaceLive` -- owned
  and routed by Web, naming no pack -- resolves and hosts it at runtime.

  `apps/0` and `actions/0` stay empty for the reason they do in every pack: the
  contributions come from the manifest at `priv/allbert_plugin.json`, and
  declaring them here as well would contribute them twice. The plugin declares
  no `settings_schema/0` (verified: its manifest lists only the `apps`
  contribution), so this pack needs no settings fragment either.
  """

  @behaviour AllbertAssist.Pack

  alias AllbertAssist.Pack.Descriptor

  @application_version Mix.Project.config()[:version]
  @empty_callbacks [
    :apps,
    :actions,
    :settings_migrations,
    :settings_fragments,
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
      id: "allbert_artifacts",
      application: :allbert_artifacts,
      application_version: @application_version,
      capability_tier: :native,
      provenance: %{source: :signed_release, component: "beam-allbert-artifacts"},
      # Continues the 100 spacing: kernel 0, residual 100, ... whatsapp 1200.
      registry_order: 1300
    }
  end

  for callback <- @empty_callbacks do
    @impl true
    def unquote(callback)(), do: []
  end

  @impl true
  def surfaces, do: [%{surface_id: "artifacts", module: AllbertArtifactsWeb.ArtifactLive}]

  @impl true
  def test_lanes do
    [
      %{
        owner_id: :artifacts,
        application: :allbert_artifacts,
        cwd: "apps/allbert_artifacts",
        production_source_roots: ["apps/allbert_artifacts/lib"],
        test_roots: ["apps/allbert_artifacts/test"],
        test_support_roots: [],
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
        historical_metrics_aliases: ["artifacts"]
      }
    ]
  end
end
