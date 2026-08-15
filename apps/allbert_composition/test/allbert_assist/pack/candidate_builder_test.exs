defmodule AllbertAssist.Pack.CandidateBuilderTest do
  use ExUnit.Case, async: false
  alias AllbertAssist.DevGates.GateOwners

  @moduletag :global_process_serial
  @moduletag timeout: 120_000

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.App.Registry.MetadataSnapshot, as: AppSnapshot
  alias AllbertAssist.DevGates.V14M1RegistryShadowParity, as: ShadowParity

  alias AllbertAssist.Pack.{
    ActionProjection,
    CandidateBuilder,
    Canonical,
    CompatibilityAlias,
    Contribution,
    ProjectionProvider
  }

  alias AllbertAssist.Pack.CandidateBuilder.ExtractedAliases

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
  # v1.4 M13 re-froze this digest. The extraction completed: fifteen
  # descriptor-bearing applications instead of five, and each pack now
  # contributes its own gate owner lane, settings fragment owner, CLI group and
  # -- for the seven channels -- an effect subtree it supervises itself. As at M9
  # and M12, no contribution was added or removed, only re-attributed to the
  # application that owns it.
  # v1.4 M13.1 re-froze this digest, and unlike M9, M12 and M13 this one IS a
  # removal. Those three re-attributed contributions between applications; this
  # takes one out. The M0 ledger's registration subject implemented the Plugin
  # behaviour, which was the whole test the compiled inventory applied, so a gate
  # fixture was counted as a fourteenth shipped plugin and reached the candidate
  # through the shipped-registry fixture. `AllbertAssist.Plugin.product?/0` now
  # declares product membership and the subject declares false, so the candidate
  # binds the thirteen real packs. Nothing the product ships changed.
  # v1.4 M17.a re-froze this digest for the release identity. The descriptor
  # application versions are authority bytes, so moving all seventeen OTP apps
  # from 1.3.2 to 1.4.0 changes the canonical candidate without changing its
  # contribution roster or permissions.
  # v1.4 M17.b re-froze the internal component boundary after packaged FV found
  # that the thirteen extracted manifests were still effective legacy owners.
  # Their rows now belong to the exact compiled Pack targets; the old carriers
  # remain snapshot-inert, digest-bound deprecated aliases. The three action aliases are
  # unchanged and independently validated.
  @expected_behavior_digest "820b9eda8d992e25edcf346c6b1e556941ae8ff913f9a79478805000f51fc62d"
  @expected_bytes_sha256 "5872bf1b69e5cdb7d76005a998d2c8dc96d8974c6bd1b3b986512d8fac46b169"
  @expected_extracted_aliases [
    {"allbert.artifacts", "AllbertArtifacts.Plugin", "allbert_artifacts",
     "AllbertArtifacts.Pack"},
    {"allbert.browser", "AllbertBrowser.Plugin", "allbert_browser", "AllbertBrowser.Pack"},
    {"allbert.discord", "AllbertDiscord.Plugin", "allbert_discord", "AllbertDiscord.Pack"},
    {"allbert.email", "AllbertEmail.Plugin", "allbert_email", "AllbertEmail.Pack"},
    {"allbert.matrix", "AllbertMatrix.Plugin", "allbert_matrix", "AllbertMatrix.Pack"},
    {"allbert.notes_files", "AllbertNotesFiles.Plugin", "allbert_notes_files",
     "AllbertNotesFiles.Pack"},
    {"allbert.research", "AllbertResearch.Plugin", "allbert_research", "AllbertResearch.Pack"},
    {"allbert.signal", "AllbertSignal.Plugin", "allbert_signal", "AllbertSignal.Pack"},
    {"allbert.slack", "AllbertSlack.Plugin", "allbert_slack", "AllbertSlack.Pack"},
    {"allbert.telegram", "AllbertTelegram.Plugin", "allbert_telegram", "AllbertTelegram.Pack"},
    {"allbert.tui", "AllbertTUI.Plugin", "allbert_tui", "AllbertTUI.Pack"},
    {"allbert.whatsapp", "AllbertWhatsApp.Plugin", "allbert_whatsapp", "AllbertWhatsApp.Pack"},
    {"stocksage", "StockSage.Plugin", "allbert_stocksage", "StockSage.Pack"}
  ]

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
  test "all extracted source contributions are inert aliases to exact compiled Pack owners",
       context do
    assert {:ok, candidate} =
             CandidateBuilder.build(context.closed, context.apps, context.plugins)

    compiled = Enum.filter(candidate.contributions, &(&1.owner.kind == :compiled_pack))

    deprecated =
      Enum.filter(candidate.contributions, &(&1.compatibility.kind == :deprecated_alias))

    native_aliases = Enum.filter(candidate.compatibility_aliases, &(&1.kind == :deprecated_alias))
    action_aliases = Enum.filter(candidate.compatibility_aliases, &(&1.kind == :legacy_plugin))

    assert length(compiled) == 15
    assert length(deprecated) == 13
    assert length(native_aliases) == 13
    assert length(action_aliases) == 3

    assert Enum.all?(action_aliases, &(&1.target.kind == :action))

    assert ExtractedAliases.mappings() == @expected_extracted_aliases

    assert Enum.all?(ExtractedAliases.mappings(), fn tuple ->
             tuple |> Tuple.to_list() |> Enum.all?(&is_binary/1)
           end)

    for {source_id, source_module, target_id, target_module} <- @expected_extracted_aliases do
      assert %Contribution{
               implementation_module: source_carrier,
               compatibility: %{kind: :deprecated_alias, alias_of: target}
             } = source = Enum.find(candidate.contributions, &(&1.owner.id == source_id))

      assert module_name(source_carrier) == source_module

      assert target.kind == :contribution
      assert target.owner_id == target_id
      assert target.identity == target_id

      assert %Contribution{
               owner: %{kind: :compiled_pack},
               implementation_module: target_carrier,
               compatibility: %{kind: :native}
             } = compiled_target = Enum.find(candidate.contributions, &(&1.owner.id == target_id))

      assert module_name(target_carrier) == target_module

      assert %CompatibilityAlias{
               module: alias_carrier,
               target: ^target,
               authority_sha256: digest
             } = Enum.find(native_aliases, &(&1.owner_id == source_id))

      assert module_name(alias_carrier) == source_module

      assert {:ok, authority} =
               Canonical.contribution_alias_authority(source, compiled_target)

      assert digest == authority.authority_sha256
    end

    refute Enum.any?(candidate.contributions, &(&1.compatibility.kind == :legacy_plugin))
  end

  @tag :parity
  test "extracted mapping rejects missing or carrier-mismatched first-party metadata", context do
    missing = %{
      context.plugins
      | entries: Enum.reject(context.plugins.entries, &(&1.plugin_id == "allbert.browser"))
    }

    assert {:error, [_diagnostic | _]} =
             CandidateBuilder.build(context.closed, context.apps, missing)

    mismatched = %{
      context.plugins
      | entries:
          Enum.map(context.plugins.entries, fn
            %{plugin_id: "allbert.browser"} = entry -> %{entry | module: __MODULE__}
            entry -> entry
          end)
    }

    assert {:error, [%{detail: %{reason: :extracted_alias_mapping_mismatch}}]} =
             CandidateBuilder.build(context.closed, context.apps, mismatched)

    extra_entry =
      context.plugins.entries
      |> Enum.find(&(&1.plugin_id == "allbert.browser"))
      |> Map.merge(%{
        plugin_id: "allbert.extra",
        module: __MODULE__,
        apps: [],
        channels: [],
        actions: [],
        settings_schema: [],
        children: :ignore
      })

    extra = %{context.plugins | entries: context.plugins.entries ++ [extra_entry]}

    assert {:error, [%{detail: %{reason: :extracted_alias_source_roster_mismatch}}]} =
             CandidateBuilder.build(context.closed, context.apps, extra)
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
      candidate_for(closed, plugin_entry(module: __MODULE__), static_projection: [static_action])

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
      |> GateOwners.canonical_pack_rows!()
      |> Enum.sort_by(&{&1.owner_id, &1.identity.value})

    # v1.4 M13: fifteen lanes, one per descriptor-bearing application. Before the
    # extraction the residual answered for most of them; now each pack declares
    # its own through Pack.test_lanes/0, and the residual is left with :core.
    assert length(candidate_rows) == 15
    assert candidate_rows == expected_rows
  end

  defp canonical_identity(candidate) do
    assert {:ok, snapshot} = Canonical.build_snapshot(candidate, :shadow)
    assert {:ok, bytes} = Canonical.snapshot_bytes(snapshot)
    {bytes, snapshot.behavior_digest}
  end

  defp module_name(module) do
    module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
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
