defmodule AllbertAssist.Pack.Residual do
  @moduledoc """
  Pack descriptor for the transitional residual Allbert application.

  The residual is a native Pack and extraction queue, not a second kernel.
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

  @settings_fragment_modules [
    AllbertAssist.Settings.FragmentOwners.AcpServer,
    AllbertAssist.Settings.FragmentOwners.ActiveMemory,
    AllbertAssist.Settings.FragmentOwners.Allbert,
    AllbertAssist.Settings.FragmentOwners.AppRegistry,
    AllbertAssist.Settings.FragmentOwners.Artifacts,
    AllbertAssist.Settings.FragmentOwners.Channels,
    AllbertAssist.Settings.FragmentOwners.Coding,
    AllbertAssist.Settings.FragmentOwners.Confirmations,
    AllbertAssist.Settings.FragmentOwners.Conversations,
    AllbertAssist.Settings.FragmentOwners.DynamicCodegen,
    AllbertAssist.Settings.FragmentOwners.Execution,
    AllbertAssist.Settings.FragmentOwners.ExternalServices,
    AllbertAssist.Settings.FragmentOwners.FirstModel,
    AllbertAssist.Settings.FragmentOwners.Image,
    AllbertAssist.Settings.FragmentOwners.Intent,
    AllbertAssist.Settings.FragmentOwners.Jobs,
    AllbertAssist.Settings.FragmentOwners.Marketplace,
    AllbertAssist.Settings.FragmentOwners.Mcp,
    AllbertAssist.Settings.FragmentOwners.McpServer,
    AllbertAssist.Settings.FragmentOwners.Memory,
    AllbertAssist.Settings.FragmentOwners.ModelPreferences,
    AllbertAssist.Settings.FragmentOwners.ModelRoles,
    AllbertAssist.Settings.FragmentOwners.Models,
    AllbertAssist.Settings.FragmentOwners.Objectives,
    AllbertAssist.Settings.FragmentOwners.OpenaiApi,
    AllbertAssist.Settings.FragmentOwners.Operator,
    AllbertAssist.Settings.FragmentOwners.PackageInstalls,
    AllbertAssist.Settings.FragmentOwners.Permissions,
    AllbertAssist.Settings.FragmentOwners.Plan,
    AllbertAssist.Settings.FragmentOwners.Plugins,
    AllbertAssist.Settings.FragmentOwners.PublicProtocol,
    AllbertAssist.Settings.FragmentOwners.ResourceGrants,
    AllbertAssist.Settings.FragmentOwners.Runtime,
    AllbertAssist.Settings.FragmentOwners.Sandbox,
    AllbertAssist.Settings.FragmentOwners.Search,
    AllbertAssist.Settings.FragmentOwners.SelfImprovement,
    AllbertAssist.Settings.FragmentOwners.Sessions,
    AllbertAssist.Settings.FragmentOwners.Skills,
    AllbertAssist.Settings.FragmentOwners.SurfacePolicy,
    AllbertAssist.Settings.FragmentOwners.Templates,
    AllbertAssist.Settings.FragmentOwners.Vision,
    AllbertAssist.Settings.FragmentOwners.Voice,
    AllbertAssist.Settings.FragmentOwners.Workflows,
    AllbertAssist.Settings.FragmentOwners.Workspace
  ]

  @impl true
  def descriptor do
    %Descriptor{
      schema_version: 1,
      id: "allbert_assist",
      application: :allbert_assist,
      application_version: @application_version,
      capability_tier: :native,
      provenance: %{source: :signed_release, component: "beam-allbert-assist"},
      registry_order: 100
    }
  end

  for callback <- @empty_callbacks do
    @impl true
    def unquote(callback)(), do: []
  end

  @impl true
  def settings_fragments, do: @settings_fragment_modules

  # The kernel concerns relocating at M8 read facts and perform effects that
  # still live here. Each row names the residual adapter that answers for one
  # sealed contract; composition pairs them with this pack's own application and
  # the binder validates the complete set before readiness opens. A row leaves
  # this list when its subsystem extracts into a pack that answers for itself.
  @impl true
  def kernel_contracts do
    [
      {:actions_overlay, AllbertAssist.Pack.Contracts.ActionsOverlay},
      {:confirmations, AllbertAssist.Pack.Contracts.Confirmations},
      {:grants, AllbertAssist.Pack.Contracts.Grants},
      {:home_roots, AllbertAssist.Pack.Contracts.HomeRoots},
      {:membership, AllbertAssist.Pack.Contracts.Membership},
      {:release_availability, AllbertAssist.Pack.Contracts.ReleaseAvailability},
      {:resource_refs, AllbertAssist.Pack.Contracts.ResourceRefs},
      {:response_values, AllbertAssist.Pack.Contracts.ResponseValues},
      {:settings, AllbertAssist.Pack.Contracts.Settings},
      {:signals, AllbertAssist.Pack.Contracts.Signals},
      {:skills, AllbertAssist.Pack.Contracts.Skills}
    ]
  end

  @impl true
  def test_lanes do
    [
      owner(:core, "apps/allbert_assist", "apps/allbert_assist/lib", "apps/allbert_assist/test",
        support: ["apps/allbert_assist/test/support"],
        aliases: ["core", "serial-core"],
        production_roots: [
          "apps/allbert_assist/lib",
          "plugins/allbert.tui/lib"
        ]
      ),
      owner(:stocksage, "apps/allbert_assist", "plugins/stocksage/lib", "plugins/stocksage/test",
        support: ["plugins/stocksage/test/support"]
      ),
      owner(
        :discord,
        "apps/allbert_assist",
        "plugins/allbert.discord/lib",
        "plugins/allbert.discord/test"
      ),
      owner(
        :slack,
        "apps/allbert_assist",
        "plugins/allbert.slack/lib",
        "plugins/allbert.slack/test"
      ),
      owner(
        :matrix,
        "apps/allbert_assist",
        "plugins/allbert.matrix/lib",
        "plugins/allbert.matrix/test"
      ),
      owner(
        :whatsapp,
        "apps/allbert_assist",
        "plugins/allbert.whatsapp/lib",
        "plugins/allbert.whatsapp/test"
      ),
      owner(
        :signal,
        "apps/allbert_assist",
        "plugins/allbert.signal/lib",
        "plugins/allbert.signal/test"
      ),
      owner(
        :artifacts,
        "apps/allbert_assist",
        "plugins/allbert.artifacts/lib",
        "plugins/allbert.artifacts/test"
      )
    ]
  end

  defp owner(owner_id, cwd, production_root, test_root, opts \\ []) do
    %{
      owner_id: owner_id,
      application: :allbert_assist,
      cwd: cwd,
      production_source_roots: Keyword.get(opts, :production_roots, [production_root]),
      test_roots: [test_root],
      test_support_roots: Keyword.get(opts, :support, []),
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
      historical_metrics_aliases: Keyword.get(opts, :aliases, [Atom.to_string(owner_id)])
    }
  end
end
