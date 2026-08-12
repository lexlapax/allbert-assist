defmodule AllbertWhatsApp.Pack do
  @moduledoc """
  Pack descriptor for the extracted Allbert WhatsApp Channel.

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
      id: "allbert_whatsapp",
      application: :allbert_whatsapp,
      application_version: @application_version,
      capability_tier: :native,
      provenance: %{source: :signed_release, component: "beam-allbert-whatsapp"},
      registry_order: 1200
    }
  end

  for callback <- @empty_callbacks do
    @impl true
    def unquote(callback)(), do: []
  end

  @impl true
  def settings_fragments, do: [AllbertWhatsApp.SettingsFragment]

  @impl true
  def cli_groups do
    [
      %{
        group_id: "allbert_whatsapp.channels",
        command_path: ["admin", "channels", "whatsapp"],
        module: AllbertWhatsApp.CLI
      }
    ]
  end

  @impl true
  def test_lanes do
    [
      %{
        owner_id: :whatsapp,
        application: :allbert_whatsapp,
        cwd: "apps/allbert_whatsapp",
        production_source_roots: ["apps/allbert_whatsapp/lib"],
        test_roots: ["apps/allbert_whatsapp/test"],
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
        historical_metrics_aliases: ["whatsapp"]
      }
    ]
  end
end
