defmodule AllbertNotesFiles.Pack do
  @moduledoc """
  Pack descriptor for the extracted notes/files application.

  The first pack to leave `plugins/` and become an umbrella sibling, so this is
  the template telegram and email reuse at M12.

  `apps/0` and `actions/0` stay empty deliberately. The pack's apps and actions
  are contributed by its manifest, which now lives at `priv/allbert_plugin.json`
  and is read by `AllbertAssist.Plugin.Discovery.extracted_pack_manifests/1`.
  Declaring them here as well would contribute them twice, which M9's acceptance
  forbids. Kernel and residual leave the same callbacks empty for the same
  reason: a descriptor states what the pack IS, not a second copy of what it
  contributes.
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
      id: "allbert_notes_files",
      application: :allbert_notes_files,
      application_version: @application_version,
      capability_tier: :native,
      provenance: %{source: :signed_release, component: "beam-allbert-notes-files"},
      # Operator decision 2026-08-11: continue the 100 spacing after kernel 0 and
      # residual 100, leaving room to insert a tier without renumbering a token
      # that is frozen into the catalog row and the .app.
      registry_order: 200
    }
  end

  for callback <- @empty_callbacks do
    @impl true
    def unquote(callback)(), do: []
  end

  # Operator decision 2026-08-11: the pack answers for its own settings the way
  # M5 models ownership, rather than continuing to contribute through the App
  # path. The fragment's `id` and `owner` are hardcoded literals and its keys are
  # namespaced on the app id, so stored identity survives the move -- which is
  # the property M9 exists to prove, and it is asserted rather than assumed.
  @impl true
  def settings_fragments, do: [AllbertNotesFiles.SettingsFragment]

  # v1.4 M12: the pack owns its `allbert admin notes` surface. M9 left this area
  # in the residual, hand-registered in `CLI.Commands`, because `cli_groups/0`
  # had no consumer at the time. Now that M12 built one for telegram and email,
  # leaving notes_files hand-registered would be the only pack whose CLI someone
  # else declares -- so it moves here rather than banking the inconsistency.
  @impl true
  def cli_groups do
    [
      %{
        group_id: "allbert_notes_files.notes",
        command_path: ["admin", "notes"],
        module: AllbertNotesFiles.CLI
      }
    ]
  end

  # Operator decision 2026-08-11: keep :allbert_test_raw. The move's acceptance
  # is that observable behaviour is preserved, and this owner has always used it.
  @impl true
  def test_lanes do
    [
      %{
        owner_id: :notes_files,
        application: :allbert_notes_files,
        cwd: "apps/allbert_notes_files",
        production_source_roots: ["apps/allbert_notes_files/lib"],
        test_roots: ["apps/allbert_notes_files/test"],
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
        historical_metrics_aliases: ["notes_files"]
      }
    ]
  end
end
