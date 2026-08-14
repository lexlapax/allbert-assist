defmodule AllbertTUI.Pack do
  @moduledoc """
  Pack descriptor for the extracted Allbert TUI Channel.

  One of the six channels M13 extracted after telegram and email proved the
  shape at M12. The mechanisms it relies on already existed by then: a
  pack-owned CLI group, an identity-preserving settings move, and a channel
  descriptor whose adapter the residual supervises.
  """

  @behaviour AllbertAssist.Pack

  alias AllbertAssist.Pack.Descriptor

  @application_version Mix.Project.config()[:version]
  # v1.4 M15.1: `channels` stays here deliberately, matching every other
  # channel pack (allbert_slack, allbert_discord, allbert_matrix,
  # allbert_signal, allbert_email, allbert_whatsapp, allbert_telegram all
  # leave it in the same list). `AllbertAssist.Pack.channels/0` is a distinct,
  # currently-unconsumed contribution-row callback -- the real channel
  # registry is `AllbertTUI.Plugin.channels/0` below, already implemented and
  # read by `AllbertAssist.Plugin.Registry`/`Channels`. Promoting this one
  # would diverge from that precedent for no consumer.
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
      id: "allbert_tui",
      application: :allbert_tui,
      application_version: @application_version,
      capability_tier: :native,
      provenance: %{source: :signed_release, component: "beam-allbert-tui"},
      registry_order: 1100
    }
  end

  for callback <- @empty_callbacks do
    @impl true
    def unquote(callback)(), do: []
  end

  @impl true
  def settings_fragments, do: [AllbertTUI.SettingsFragment]

  # v1.4 M15.1: every other extracted channel pack declares a CLI group under
  # `["admin", "channels", <channel>]`; TUI was the one channel pack with
  # none. The TUI channel is `trust_class: :local` with no external identity,
  # bot token, or secret to configure (`secret_refs: []`), so there is no
  # channel-specific administration surface to add beyond what
  # `AllbertAssist.CLI.Areas.Channels` already provides generically (`list`,
  # `show`, `status`, `--parity`, `setup-check`). Declaring the group closes
  # the mechanism gap without inventing product surface this milestone did
  # not ask for; see `AllbertTUI.CLI` for the usage-only dispatch.
  @impl true
  def cli_groups do
    [
      %{
        group_id: "allbert_tui.channels",
        command_path: ["admin", "channels", "tui"],
        module: AllbertTUI.CLI
      }
    ]
  end

  @impl true
  def test_lanes do
    [
      %{
        owner_id: :tui,
        application: :allbert_tui,
        cwd: "apps/allbert_tui",
        production_source_roots: ["apps/allbert_tui/lib"],
        test_roots: ["apps/allbert_tui/test"],
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
        historical_metrics_aliases: ["tui"]
      }
    ]
  end
end
