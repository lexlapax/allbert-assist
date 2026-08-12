defmodule AllbertAssist.Pack.CandidateBuilderTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial
  @moduletag timeout: 120_000

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.App.Registry.MetadataSnapshot, as: AppSnapshot
  alias AllbertAssist.DevGates.V14M1RegistryShadowParity, as: ShadowParity

  alias AllbertAssist.Pack.{
    ActionProjection,
    CandidateBuilder,
    Canonical,
    ProjectionProvider
  }

  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugin.Registry.MetadataEntry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry.MetadataSnapshot, as: PluginSnapshot
  alias AllbertAssist.Settings.Fragments, as: SettingsFragments
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures

  # v1.4 M8 re-froze this digest. Relocation moved the Security suite into the
  # kernel, so the kernel gate owner now declares the lane that suite carries,
  # and a gate-owner contribution is part of the Pack candidate. The change was
  # isolated before it was accepted: reverting only the lane declaration
  # restores the previous digest exactly, which proves the relocated files
  # themselves changed no contribution.
  # v1.4 M9 re-froze this digest. The notes_files pack became an umbrella sibling,
  # so its descriptor is a third row in the closed projection and its
  # contributions -- gate owner lane, settings fragment owner, skill root -- now
  # reach the candidate through the pack rather than through the residual. The
  # candidate legitimately changed; no contribution was added or removed, only
  # re-attributed to the application that owns it.
  # v1.4 M12 re-froze this digest. Telegram and email became umbrella siblings,
  # so the closed projection carries five rows instead of three and each pack's
  # contributions -- its gate owner lane, its settings fragment owner, and the
  # CLI group it now declares through cli_groups/0 -- reach the candidate through
  # the pack rather than through the residual. As at M9, no contribution was
  # added or removed, only re-attributed to the application that owns it.
  @expected_behavior_digest "2046202bfaa3e1bf65240d43d22d82bf810660439ca3a748d9720eb0f8473a00"
  @expected_bytes_sha256 "223e969e6fe89f6d187aacc974c1022cbd35c28acc2e386954af3185d6383f65"

  setup context do
    if context[:parity] do
      registry_context = Fixtures.start_shipped_registries(:candidate_builder_parity)

      assert {:ok, closed} = ProjectionProvider.closed()

      assert {:ok, apps, _app_subscription} =
               AppRegistry.snapshot_and_subscribe(self(), registry_context[:app])

      assert {:ok, plugins, _plugin_subscription} =
               PluginRegistry.snapshot_and_subscribe(self(), registry_context[:plugin])

      %{closed: closed, apps: apps, plugins: plugins}
    else
      :ok
    end
  end

  @tag :parity
  test "complete candidate matches accepted M1.b identity and every frozen M0 binding", context do
    assert {:ok, builder_candidate} =
             CandidateBuilder.build(context.closed, context.apps, context.plugins)

    assert {builder_bytes, builder_digest} = canonical_identity(builder_candidate)
    assert builder_digest == @expected_behavior_digest

    assert :crypto.hash(:sha256, builder_bytes) |> Base.encode16(case: :lower) ==
             @expected_bytes_sha256

    assert :ok =
             ShadowParity.verify_m0_bindings!(builder_candidate, ShadowParity.prepare_m0!())

    assert Enum.map(builder_candidate.action_bindings, & &1.registry_order) ==
             Enum.to_list(1..281)

    assert Enum.all?(
             builder_candidate.action_bindings,
             &(&1.registry_order == &1.legacy_index)
           )
  end

  @tag :parity
  test "static-action and core-settings inputs each affect independently built bytes", context do
    assert {:ok, static} = ActionProjection.static()
    assert {:ok, baseline} = CandidateBuilder.build(context.closed, context.apps, context.plugins)

    [first | rest] = static

    changed_static =
      [
        Map.update!(first, :normalized_capability, &Map.put(&1, :notes, "candidate-builder-test"))
        | rest
      ]

    assert {:ok, static_mutation} =
             CandidateBuilder.build(context.closed, context.apps, context.plugins,
               static_projection: changed_static
             )

    [core | remaining] = SettingsFragments.core_fragments()
    changed_core = %{core | metadata: Map.put(core.metadata, :parity_probe, true)}

    assert {:ok, core_mutation} =
             CandidateBuilder.build(context.closed, context.apps, context.plugins,
               settings_fragments: [changed_core | remaining]
             )

    {baseline_bytes, _} = canonical_identity(baseline)
    {static_bytes, _} = canonical_identity(static_mutation)
    {core_bytes, _} = canonical_identity(core_mutation)

    refute baseline_bytes == static_bytes
    refute baseline_bytes == core_bytes
  end

  @tag :parity
  test "Plugin metadata mutation classes change the candidate or fail closed", _context do
    # A deliberately minimal candidate -- empty snapshots, no static projection,
    # one synthetic plugin -- so nothing else can dangle and the build is cheap
    # enough to repeat once per mutation class.
    #
    # v1.4 M9 put the notes_files pack into the FULL closed projection, and its
    # settings fragment is app-sourced, so it resolves its owner through the App
    # snapshot and an empty one fails with :invalid_settings_fragment. Growing the
    # fixture to satisfy the pack does not work: the full App snapshot dangles
    # CoreApp's static actions, adding only the pack's App and plugin breaks the
    # 1..N sequence with actions 261..263, and real snapshots with a derived
    # static projection is correct but rebuilds the full candidate once per
    # mutation and exceeds the budget.
    #
    # So the projection narrows rather than the fixture growing. This row tests
    # whether plugin metadata participates in candidate assembly, not pack
    # composition, and closes over only what its fixture can satisfy.
    closed = ShadowParity.source_closed_projection!([:allbert_kernel, :allbert_assist])

    baseline = candidate_for(closed, plugin_entry())

    for {field, value} <- [
          plugin_id: "candidate-plugin-changed",
          status: :disabled,
          trust_status: :untrusted,
          module: __MODULE__
        ] do
      changed = candidate_for(closed, struct!(plugin_entry(), %{field => value}))

      refute canonical_identity(baseline) == canonical_identity(changed),
             "expected #{field} to participate in Candidate assembly"
    end

    skill_plugin =
      plugin_entry(
        root_path: "/tmp/candidate-plugin",
        skill_paths: ["/tmp/candidate-plugin/skills"]
      )

    refute canonical_identity(baseline) ==
             canonical_identity(candidate_for(closed, skill_plugin))

    legacy_plugin = candidate_for(closed, plugin_entry(module: __MODULE__))

    legacy_child =
      candidate_for(
        closed,
        plugin_entry(
          module: __MODULE__,
          children: %{id: "candidate-child", start: {Task, :start_link, []}, restart: :temporary}
        ),
        []
      )

    refute canonical_identity(legacy_plugin) == canonical_identity(legacy_child)

    assert {:ok, [static_action | _]} = ActionProjection.static()

    static_baseline =
      candidate_for(closed, plugin_entry(module: __MODULE__),
        static_projection: [static_action]
      )

    static_action_mutation =
      candidate_for(
        closed,
        plugin_entry(module: __MODULE__, actions: [static_action.module]),
        static_projection: [static_action]
      )

    refute canonical_identity(static_baseline) == canonical_identity(static_action_mutation)

    settings_baseline =
      candidate_for_with_derived_settings(closed, plugin_entry(module: __MODULE__))

    settings_mutation =
      candidate_for_with_derived_settings(
        closed,
        plugin_entry(
          module: __MODULE__,
          settings_schema: [%{key: "plugins.candidate.enabled", type: :boolean, default: false}]
        )
      )

    refute canonical_identity(settings_baseline) == canonical_identity(settings_mutation)

    assert {:error, _diagnostics} =
             CandidateBuilder.build(
               closed,
               %AppSnapshot{schema_version: 1, generation: 0, entries: []},
               %PluginSnapshot{
                 schema_version: 1,
                 generation: 0,
                 entries: [plugin_entry(apps: [__MODULE__])]
               },
               static_projection: [],
               settings_fragments: [],
               intent_descriptors: []
             )
  end

  test "composition source never reaches legacy or live registry inputs" do
    source_paths = [
      "lib/allbert_assist/pack/candidate_builder.ex",
      "lib/allbert_assist/pack/candidate_builder/action_assembly.ex",
      "lib/allbert_assist/pack/candidate_builder/metadata_rows.ex",
      "lib/allbert_assist/pack/candidate_builder/channel_rows.ex",
      "lib/allbert_assist/pack/candidate_builder/compatibility_evidence.ex"
    ]

    source =
      source_paths
      |> Enum.map(&Path.join([File.cwd!(), &1]))
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    refute source =~ ~r/\bLegacyAdapter\./
    refute source =~ ~r/\b(?:ActionsRegistry|Registry)\.(?:modules|capabilities)\b/
    refute source =~ ~r/\bSettingsFragments\.registered_fragments\b/
    refute source =~ ~r/\bExtensionsRegistry\.contributions\b/
  end

  @tag :parity
  test "candidate test-lane callbacks equal the canonical Pack-backed gate projection", context do
    assert {:ok, candidate} =
             CandidateBuilder.build(context.closed, context.apps, context.plugins)

    candidate_rows =
      candidate.contributions
      |> Enum.flat_map(& &1.callbacks.test_lanes)
      |> Enum.sort_by(&{&1.owner_id, &1.identity.value})

    expected_rows =
      context.closed
      |> AllbertAssist.DevGates.GateOwners.canonical_pack_rows!()
      |> Enum.sort_by(&{&1.owner_id, &1.identity.value})

    assert length(candidate_rows) == 12
    assert candidate_rows == expected_rows
  end

  defp canonical_identity(candidate) do
    assert {:ok, snapshot} = Canonical.build_snapshot(candidate, :shadow)
    assert {:ok, bytes} = Canonical.snapshot_bytes(snapshot)
    {bytes, snapshot.behavior_digest}
  end

  defp candidate_for(closed, plugin, opts \\ []) do
    opts =
      Keyword.merge([static_projection: [], settings_fragments: [], intent_descriptors: []], opts)

    assert {:ok, candidate} =
             CandidateBuilder.build(
               closed,
               %AppSnapshot{schema_version: 1, generation: 0, entries: []},
               %PluginSnapshot{schema_version: 1, generation: 0, entries: [plugin]},
               opts
             )

    candidate
  end

  defp candidate_for_with_derived_settings(closed, plugin) do
    assert {:ok, candidate} =
             CandidateBuilder.build(
               closed,
               %AppSnapshot{schema_version: 1, generation: 0, entries: []},
               %PluginSnapshot{schema_version: 1, generation: 0, entries: [plugin]},
               static_projection: [],
               intent_descriptors: []
             )

    candidate
  end

  defp plugin_entry(overrides \\ []) do
    attrs =
      [
        plugin_id: "candidate-plugin",
        display_name: "Candidate plugin",
        source: :local,
        status: :enabled,
        trust_status: :trusted,
        module: nil,
        apps: [],
        channels: [],
        actions: [],
        root_path: nil,
        skill_paths: [],
        settings_schema: [],
        children: :ignore
      ]
      |> Keyword.merge(overrides)

    struct!(PluginEntry, attrs)
  end
end
