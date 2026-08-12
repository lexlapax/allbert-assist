defmodule AllbertMatrix.Pack do
  @moduledoc """
  Pack descriptor for the extracted Allbert Matrix Channel.

  One of the six channels M13 extracted after telegram and email proved the
  shape at M12. The mechanisms it relies on already existed by then: a
  pack-owned CLI group, an identity-preserving settings move, and a channel
  descriptor whose adapter the residual supervises.
  """

  @behaviour AllbertAssist.Pack

  alias AllbertAssist.Pack.Descriptor

  @application_version Mix.Project.config()[:version]
  @empty_callbacks [
    :apps,
    :actions,
    :settings_migrations,
    :channels,
    :surfaces,
    :skill_roots,
    :home_roots,
    :jobs,
    :stores,
    :prompt_rules,
    :intent_descriptors,
    :release_assets
  ]

  @impl true
  def descriptor do
    %Descriptor{
      schema_version: 1,
      id: "allbert_matrix",
      application: :allbert_matrix,
      application_version: @application_version,
      capability_tier: :native,
      provenance: %{source: :signed_release, component: "beam-allbert-matrix"},
      registry_order: 800
    }
  end

  for callback <- @empty_callbacks do
    @impl true
    def unquote(callback)(), do: []
  end

  @impl true
  def settings_fragments, do: [AllbertMatrix.SettingsFragment]

  @impl true
  def cli_groups do
    [
      %{
        group_id: "allbert_matrix.channels",
        command_path: ["admin", "channels", "matrix"],
        module: AllbertMatrix.CLI
      }
    ]
  end

  @impl true
  def test_lanes do
    [
      %{
        owner_id: :matrix,
        application: :allbert_matrix,
        cwd: "apps/allbert_matrix",
        production_source_roots: ["apps/allbert_matrix/lib"],
        test_roots: ["apps/allbert_matrix/test"],
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
        historical_metrics_aliases: ["matrix"]
      }
    ]
  end
end
