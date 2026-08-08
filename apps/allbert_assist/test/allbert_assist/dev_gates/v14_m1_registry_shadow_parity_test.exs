defmodule AllbertAssist.DevGates.V14M1RegistryShadowParityTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.DevGates.V14M1RegistryShadowParity
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.Pack.{LegacyAdapter, Projection, Registry}
  alias AllbertAssist.Pack.Projection.Closed
  alias AllbertAssist.Pack.Registry.Candidate
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures
  alias Jido.Signal.Bus

  @fixture Path.expand(
             "../../../../allbert_kernel/test/fixtures/v1.4/pack_row_schema_contract.json",
             __DIR__
           )

  defmodule OverlayDirectAnswer do
    use AllbertAssist.Action,
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required,
      name: "direct_answer",
      description: "M1.a2 overlay precedence probe.",
      category: "test",
      schema: []

    @impl true
    def run(_params, _context), do: {:ok, %{status: :completed}}
  end

  test "generated row-schema contract fixture is exact and self-validating" do
    live = V14M1RegistryShadowParity.row_schema_contract_fixture()
    frozen = V14M1RegistryShadowParity.load_row_schema_contract_fixture!()

    assert V14M1RegistryShadowParity.row_schema_contract_fixture_path() == @fixture

    assert Map.keys(live) |> Enum.sort() ==
             ~w[normalization schema_contract schema_contract_sha256 schema_version]

    assert live["schema_version"] == 1
    assert live["normalization"] == "v14_pack_row_schema_contract_v1"
    assert is_list(live["schema_contract"])
    assert live["schema_contract_sha256"] =~ ~r/^[0-9a-f]{64}$/
    assert frozen == live
    assert :ok = V14M1RegistryShadowParity.check_row_schema_contract_fixture!()
  end

  test "source Pack projection is sealed to the complete application closure" do
    assert %Closed{
             schema_version: 1,
             closed_applications: [
               :allbert_kernel,
               :allbert_assist,
               :allbert_composition,
               :allbert_assist_web
             ],
             pack_applications: [:allbert_kernel, :allbert_assist],
             rows: [kernel, residual],
             projection_sha256: projection_sha256,
             closure_sha256: closure_sha256
           } = closed = V14M1RegistryShadowParity.source_closed_projection!()

    assert kernel.application == :allbert_kernel
    assert residual.application == :allbert_assist
    assert kernel.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert residual.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert projection_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert closure_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert :ok = Projection.validate_closed(closed)
  end

  @tag timeout: 120_000
  test "shadow finalization matches source, private shipped registries, and a populated overlay without legacy mutation" do
    prepared_m0 = V14M1RegistryShadowParity.prepare_m0!()
    closed = V14M1RegistryShadowParity.source_closed_projection!()
    context = Fixtures.start_shipped_registries(:v14_m1_shadow_parity)
    overlay = unique_name(:v14_m1_shadow_overlay)
    registry = unique_name(:v14_m1_shadow_registry)

    start_supervised!(Supervisor.child_spec({ActionsOverlay, name: overlay}, id: overlay))

    assert :ok =
             ActionsOverlay.register_many(
               [
                 %{
                   name: OverlayDirectAnswer.name(),
                   module: OverlayDirectAnswer,
                   slug: "v14-m1-shadow-direct-answer",
                   revision: "1",
                   exposure: :agent
                 }
               ],
               server: overlay,
               existing_names: []
             )

    selected_context = Keyword.put(context, :actions_overlay, overlay)

    assert OverlayDirectAnswer in ActionsRegistry.modules(selected_context)
    assert {:ok, DirectAnswer} = ActionsRegistry.resolve("direct_answer", selected_context)

    start_supervised!(
      Supervisor.child_spec(
        {Registry, name: registry, publication: :shadow, coordinator: self()},
        id: registry
      )
    )

    for pattern <- ["allbert.app.**", "allbert.plugin.**", "allbert.action.**"] do
      assert {:ok, _subscription} = Bus.subscribe(AllbertAssist.SignalBus, pattern)
    end

    before = V14M1RegistryShadowParity.legacy_observation(selected_context)

    assert {:ok, %Candidate{} = source_candidate} =
             LegacyAdapter.capture(pack_projection: closed)

    assert {:ok, %Candidate{} = private_candidate} =
             LegacyAdapter.capture([{:pack_projection, closed} | context])

    assert {:ok, %Candidate{} = overlay_candidate} =
             LegacyAdapter.capture([{:pack_projection, closed} | selected_context])

    assert_exact_candidate_denominators!(source_candidate)

    evidence =
      V14M1RegistryShadowParity.verify_shadow!(
        closed,
        source_candidate,
        private_candidate,
        overlay_candidate,
        prepared_m0,
        registry
      )

    assert V14M1RegistryShadowParity.legacy_observation(selected_context) == before
    refute_receive {:signal, _signal}, 50
    evidence = Map.put(evidence, :zero_legacy_mutation, :pass)

    assert evidence.pack_projection_sha256 == closed.projection_sha256
    assert evidence.pack_closure_sha256 == closed.closure_sha256
    assert evidence.snapshot_bytes_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert evidence.behavior_digest =~ ~r/^[0-9a-f]{64}$/
    assert evidence.m0_registry_payload_sha256 == prepared_m0.payload_sha256
    assert evidence.row_schema_fixture_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert evidence.row_schema_contract_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert evidence.private_registry_parity == :pass
    assert evidence.overlay_exclusion_and_precedence == :pass
    assert evidence.zero_legacy_mutation == :pass

    m0_actions = prepared_m0.payload["actions"]
    m0_plugins = prepared_m0.payload["plugins"]
    plugin_declarations = Enum.sum(Enum.map(m0_plugins["entries"], &length(&1["actions"])))
    expected_aliases = plugin_declarations - m0_actions["counts"]["plugin_append"]
    expected_action_rows = m0_actions["counts"]["static"] + plugin_declarations

    assert evidence.candidate_counts.contributions ==
             length(closed.rows) + length(m0_plugins["entries"])

    assert evidence.candidate_counts.rows >= expected_action_rows
    assert evidence.candidate_counts.action_bindings == length(prepared_m0.action_rows)
    assert evidence.candidate_counts.aliases == expected_aliases

    assert evidence.candidate_counts.compatibility_diagnostics ==
             length(m0_plugins["child_specs"])
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp assert_exact_candidate_denominators!(candidate) do
    action_rows = callback_rows(candidate, :actions)

    native_action_rows =
      callback_rows(candidate, :actions, &(&1.owner.kind == :compiled_pack))

    plugin_action_rows =
      callback_rows(candidate, :actions, &(&1.owner.kind == :legacy_plugin))

    alias_source_rows = Enum.filter(action_rows, &(&1.order.namespace == :alias_target))

    app_action_refs =
      candidate
      |> callback_rows(:apps)
      |> Enum.flat_map(&Map.fetch!(&1.source_authority, "actions"))

    plugin_action_identities =
      plugin_action_rows
      |> Enum.map(&{&1.payload["module"], &1.payload["name"]})
      |> MapSet.new()

    app_plugin_dual_declarations =
      Enum.count(app_action_refs, fn ref ->
        MapSet.member?(plugin_action_identities, {ref["module"], ref["name"]})
      end)

    skill_rows = callback_rows(candidate, :skill_roots)

    app_skill_root_refs =
      candidate
      |> callback_rows(:apps)
      |> Enum.flat_map(&Map.fetch!(&1.source_authority, "skill_root_refs"))

    assert length(candidate.contributions) == 15
    assert length(action_rows) == 284
    assert length(native_action_rows) == 244
    assert length(plugin_action_rows) == 40
    assert length(action_rows -- alias_source_rows) == 281
    assert length(candidate.action_bindings) == 281
    assert Enum.map(candidate.action_bindings, & &1.registry_order) == Enum.to_list(1..281)
    assert Enum.all?(action_rows -- alias_source_rows, &(&1.order.namespace == :registry_order))
    assert length(alias_source_rows) == 3
    assert length(candidate.compatibility_aliases) == 3
    assert length(app_action_refs) == 23
    assert app_plugin_dual_declarations == 20
    assert length(skill_rows) == 2
    assert length(app_skill_root_refs) == 2
    assert length(skill_rows) + length(app_skill_root_refs) == 4
    assert Enum.count(candidate.compatibility_diagnostics, &(&1.code == :child_spec)) == 3
  end

  defp callback_rows(candidate, callback, contribution_filter \\ fn _ -> true end) do
    for contribution <- candidate.contributions,
        contribution_filter.(contribution),
        row <- Map.fetch!(contribution.callbacks, callback),
        do: row
  end
end
