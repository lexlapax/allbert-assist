defmodule AllbertTelegram.Pack do
  @moduledoc """
  Pack descriptor for the extracted Telegram channel.

  The second pack to leave `plugins/`, reusing the template M9 established with
  notes_files. Two things differ, and both are M12 operator decisions.

  First, this pack owns its CLI. `cli_groups/0` below is the first non-empty
  implementation of that callback anywhere in the tree: the residual's
  `allbert admin channels telegram ...` routes used to call
  `Telegram.Adapter`/`Telegram.Renderer` through compile-time aliases, which
  compiled only because the plugin source was path-injected into the residual.
  After extraction that would be a residual-to-pack return edge, which M12's
  acceptance forbids, so the command surface moves to its owner instead.

  Second, the implementation modules were renamed out of
  `AllbertAssist.Channels.Telegram.*` into this application's own namespace, so
  ownership is legible from the module name rather than only from the path.

  `apps/0` and `actions/0` stay empty for the same reason they do in
  notes_files: the pack's contributions come from its manifest at
  `priv/allbert_plugin.json`, and declaring them here as well would contribute
  them twice.
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
      id: "allbert_telegram",
      application: :allbert_telegram,
      application_version: @application_version,
      capability_tier: :native,
      provenance: %{source: :signed_release, component: "beam-allbert-telegram"},
      # Continues the 100 spacing: kernel 0, residual 100, notes_files 200.
      registry_order: 300
    }
  end

  for callback <- @empty_callbacks do
    @impl true
    def unquote(callback)(), do: []
  end

  # The pack answers for its own settings, as notes_files does. The fragment's
  # `id` and `owner` are hardcoded literals and `source: :plugin`, so stored
  # identity survives the move -- and a plugin-sourced fragment resolves by
  # owner id alone, without the App snapshot that made M9's fixtures fight back.
  @impl true
  def settings_fragments, do: [AllbertTelegram.SettingsFragment]

  # The first non-empty cli_groups/0 in the tree. The row shape is fixed by the
  # frozen `cli_group_ref_v1` schema in `AllbertAssist.Pack.RowSchemas`:
  # `group_id` is the identity, `command_path` is an ordered list of at least
  # one segment, and `module` is the implementation.
  @impl true
  def cli_groups do
    [
      %{
        group_id: "allbert_telegram.channels",
        command_path: ["admin", "channels", "telegram"],
        module: AllbertTelegram.CLI
      }
    ]
  end

  @impl true
  def test_lanes do
    [
      %{
        owner_id: :telegram,
        application: :allbert_telegram,
        cwd: "apps/allbert_telegram",
        production_source_roots: ["apps/allbert_telegram/lib"],
        test_roots: ["apps/allbert_telegram/test"],
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
        historical_metrics_aliases: ["telegram"]
      }
    ]
  end
end
