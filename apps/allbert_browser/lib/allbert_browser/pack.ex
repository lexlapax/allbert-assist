defmodule AllbertBrowser.Pack do
  @moduledoc """
  Pack descriptor for the extracted research delegate.

  The first M13 extraction, chosen to go first because it had the cleanest
  dependency position of any remaining plugin: zero compile-time references from
  residual `lib/`, its own namespace already, and a settings fragment module that
  was already shaped like the one M9 introduced.

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
    :surfaces,
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
      id: "allbert_browser",
      application: :allbert_browser,
      application_version: @application_version,
      capability_tier: :native,
      provenance: %{source: :signed_release, component: "beam-allbert-browser"},
      # Continues the 100 spacing: kernel 0, residual 100, notes_files 200,
      # telegram 300, email 400.
      registry_order: 600
    }
  end

  for callback <- @empty_callbacks do
    @impl true
    def unquote(callback)(), do: []
  end

  # 33 keys that were declared inline in the plugin module; the fragment owner is
  # now their single definition.
  @impl true
  def settings_fragments, do: [AllbertBrowser.SettingsFragment]

  @impl true
  def test_lanes do
    [
      %{
        owner_id: :browser,
        application: :allbert_browser,
        cwd: "apps/allbert_browser",
        production_source_roots: ["apps/allbert_browser/lib"],
        test_roots: ["apps/allbert_browser/test"],
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
        historical_metrics_aliases: ["browser"]
      }
    ]
  end
end
