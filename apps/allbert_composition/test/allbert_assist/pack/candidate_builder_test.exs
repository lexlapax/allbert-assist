defmodule AllbertAssist.Pack.CandidateBuilderTest do
  use ExUnit.Case, async: false

  @moduletag :home_fs_serial
  @moduletag timeout: 120_000

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.App.Registry.MetadataSnapshot, as: AppSnapshot
  alias AllbertAssist.Pack.{CandidateBuilder, Canonical, LegacyAdapter, ProjectionProvider}
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugin.Registry.MetadataEntry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry.MetadataSnapshot, as: PluginSnapshot
  alias AllbertAssist.Settings.Fragments, as: SettingsFragments
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures

  setup context do
    if context[:parity] do
      registry_context = Fixtures.start_shipped_registries(:candidate_builder_parity)

      assert {:ok, closed} = ProjectionProvider.closed()

      assert {:ok, apps, _app_subscription} =
               AppRegistry.snapshot_and_subscribe(self(), registry_context[:app])

      assert {:ok, plugins, _plugin_subscription} =
               PluginRegistry.snapshot_and_subscribe(self(), registry_context[:plugin])

      %{closed: closed, apps: apps, plugins: plugins, registry_context: registry_context}
    else
      :ok
    end
  end

  @tag :parity
  test "independently assembled candidate has exact legacy canonical bytes and digest", context do
    assert {:ok, builder_candidate} =
             CandidateBuilder.build(context.closed, context.apps, context.plugins)

    assert {:ok, legacy_candidate} =
             LegacyAdapter.capture([pack_projection: context.closed] ++ context.registry_context)

    assert {builder_bytes, builder_digest} = canonical_identity(builder_candidate)
    assert {legacy_bytes, legacy_digest} = canonical_identity(legacy_candidate)

    assert builder_bytes == legacy_bytes
    assert builder_digest == legacy_digest
  end

  @tag :parity
  test "static-action and core-settings inputs each affect independently built bytes", context do
    assert {:ok, static} = ActionsRegistry.static_projection()
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
  test "Plugin metadata mutation classes change the candidate or fail closed", context do
    baseline = candidate_for(context.closed, plugin_entry())

    for {field, value} <- [
          plugin_id: "candidate-plugin-changed",
          status: :disabled,
          trust_status: :untrusted,
          module: __MODULE__
        ] do
      changed = candidate_for(context.closed, struct!(plugin_entry(), %{field => value}))

      refute canonical_identity(baseline) == canonical_identity(changed),
             "expected #{field} to participate in Candidate assembly"
    end

    skill_plugin =
      plugin_entry(
        root_path: "/tmp/candidate-plugin",
        skill_paths: ["/tmp/candidate-plugin/skills"]
      )

    refute canonical_identity(baseline) ==
             canonical_identity(candidate_for(context.closed, skill_plugin))

    legacy_plugin = candidate_for(context.closed, plugin_entry(module: __MODULE__))

    legacy_child =
      candidate_for(
        context.closed,
        plugin_entry(
          module: __MODULE__,
          children: %{id: "candidate-child", start: {Task, :start_link, []}, restart: :temporary}
        )
      )

    refute canonical_identity(legacy_plugin) == canonical_identity(legacy_child)

    assert {:ok, [static_action | _]} = ActionsRegistry.static_projection()

    static_baseline =
      candidate_for(context.closed, plugin_entry(module: __MODULE__),
        static_projection: [static_action]
      )

    static_action_mutation =
      candidate_for(
        context.closed,
        plugin_entry(module: __MODULE__, actions: [static_action.module]),
        static_projection: [static_action]
      )

    refute canonical_identity(static_baseline) == canonical_identity(static_action_mutation)

    settings_baseline =
      candidate_for_with_derived_settings(context.closed, plugin_entry(module: __MODULE__))

    settings_mutation =
      candidate_for_with_derived_settings(
        context.closed,
        plugin_entry(
          module: __MODULE__,
          settings_schema: [%{key: "plugins.candidate.enabled", type: :boolean, default: false}]
        )
      )

    refute canonical_identity(settings_baseline) == canonical_identity(settings_mutation)

    assert {:error, _diagnostics} =
             CandidateBuilder.build(
               context.closed,
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
