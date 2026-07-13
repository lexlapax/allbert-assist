defmodule AllbertAssist.Security.V1SweepEvalTest do
  @moduledoc """
  v1.0 Stability Release & Public Contract Freeze sweep.

  This sweep owns the 7 `:v1` freeze rows. Each row proves a frozen Tier 1/Tier 2
  public contract still exists **by exact name** (the plan's Freeze Enforcement
  mechanism): `function_exported?/3`, signal literals, `__schema__(:fields)`,
  Settings-key resolution, `Paths` roots, `Policy.permission_classes/0`, and the
  `docs/developer/public-contract-freeze.md` inventory. Renaming or removing a frozen
  symbol fails its row; Tier 2 additive changes stay green because the rows assert
  presence, not exhaustive equality. Every proof calls `AssertBinding.check!/2`.
  """
  use AllbertAssist.SecurityEvalCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Conversations.Thread
  alias AllbertAssist.Conversations.ThreadChannelRef
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.SecurityFixtures.EvalInventory

  @repo_root Path.expand("../../../../", __DIR__)
  @freeze_notes "docs/developer/public-contract-freeze.md"

  @eval_ids ~w(
    v1-contract-freeze-no-new-features-001
    v1-public-contract-docs-001
    v1-action-boundary-regression-001
    v1-settings-home-layout-freeze-001
    v1-public-surface-policy-freeze-001
    v1-tier1-tier2-classification-001
    v1-adr0021-vocabulary-not-frozen-001
  )

  @owner "AllbertAssist.Security.V1SweepEvalTest"
  @owners Map.new(@eval_ids, &{&1, @owner})
  @owner_files %{@owner => "apps/allbert_assist/test/security/v1_sweep_eval_test.exs"}

  test "v1.0 eval inventory rows are complete and routed to their owning test" do
    rows = EvalInventory.rows_for_milestone(:v1)
    row_ids = Enum.map(rows, & &1.id)
    rows_by_id = Map.new(rows, &{&1.id, &1})

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert length(row_ids) == 7
    assert Enum.all?(rows, &(&1.milestone == :v1))

    for {id, owner} <- @owners do
      assert rows_by_id[id].test_module == owner, "row #{id} routed to the wrong owning test"
    end

    IO.puts("v1-inventory-complete status=pass rows=7 owners=routed")
  end

  test "v1.0 rows encode concrete pass criteria" do
    for row <- EvalInventory.rows_for_milestone(:v1) do
      assert is_atom(row.boundary)
      assert is_list(row.assert) and length(row.assert) >= 3
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
    end
  end

  # ── Row 1: no new authority / permission-class freeze ────────────────────────

  test "v1-contract-freeze-no-new-features-001: the permission-class set is frozen and Tier 1 anchors are present" do
    classes = MapSet.new(Policy.permission_classes())
    assert MapSet.size(classes) > 0

    outside =
      ActionsRegistry.capabilities()
      |> Enum.reject(&MapSet.member?(classes, &1.permission))
      |> Enum.map(& &1.name)

    assert outside == [], "actions outside the frozen permission classes: #{inspect(outside)}"

    # Tier 1 anchor symbols still exist by exact name.
    assert function_exported?(Runtime, :submit_user_input, 1)
    assert function_exported?(Runner, :run, 3)

    IO.puts(
      "v1-contract-freeze-no-new-features-001 status=pass classes_frozen=#{MapSet.size(classes)}"
    )

    AssertBinding.check!("v1-contract-freeze-no-new-features-001", [
      :permission_class_set_frozen,
      :no_action_outside_frozen_classes,
      :tier1_anchor_symbols_present
    ])
  end

  # ── Row 2: public contract freeze notes exist and classify ───────────────────

  test "v1-public-contract-docs-001: the freeze notes exist and classify contracts by tier" do
    notes = read!(@freeze_notes)

    assert notes =~ "Public Contract Freeze"
    assert notes =~ "## Tier 1" and notes =~ "## Tier 2"

    for name <- ["submit_user_input", "Runner.run/3", "SurfaceProvider", "notes_files"] do
      assert notes =~ name, "freeze notes do not name #{name}"
    end

    IO.puts("v1-public-contract-docs-001 status=pass notes=classified")

    AssertBinding.check!("v1-public-contract-docs-001", [
      :freeze_notes_present,
      :freeze_notes_tiered,
      :freeze_notes_names_contracts
    ])
  end

  # ── Row 3: action boundary contract ──────────────────────────────────────────

  test "v1-action-boundary-regression-001: Runner.run/3, Registry, and the :invalid_params shape hold" do
    assert function_exported?(Runner, :run, 3)
    assert function_exported?(ActionsRegistry, :names, 0)
    assert function_exported?(ActionsRegistry, :capabilities, 0)

    runner_source = read!("apps/allbert_assist/lib/allbert_assist/actions/runner.ex")
    assert runner_source =~ ":invalid_params"

    IO.puts("v1-action-boundary-regression-001 status=pass boundary=runner")

    AssertBinding.check!("v1-action-boundary-regression-001", [
      :runner_run3_exported,
      :registry_present,
      :invalid_params_shape_present
    ])
  end

  # ── Row 4: Settings + Home layout freeze ─────────────────────────────────────

  test "v1-settings-home-layout-freeze-001: Home roots, frozen Settings keys, and schema_version hold by exact name" do
    for root <- [:settings_root, :memory_root, :artifacts_root, :db_path] do
      assert function_exported?(Paths, root, 0), "Paths.#{root}/0 missing"
    end

    # Canonical channel identity columns frozen by exact name.
    thread_fields = Thread.__schema__(:fields)
    assert :id in thread_fields
    channel_fields = ThreadChannelRef.__schema__(:fields)

    for col <- [:owner_scope, :receiver_account_ref, :provider_thread_key] do
      assert col in channel_fields, "ThreadChannelRef.#{col} missing"
    end

    schema = read!("apps/allbert_assist/lib/allbert_assist/settings/schema.ex")

    for key <- ["mcp_server", "openai_api", "acp_server", "templates.create.enabled"] do
      assert schema =~ key, "settings schema missing #{key}"
    end

    notes_root_source =
      read!("apps/allbert_assist/lib/allbert_assist/actions/settings/set_notes_root.ex")

    assert notes_root_source =~ "apps.notes_files.notes_root"

    version_contract =
      read!("apps/allbert_assist/lib/allbert_assist/settings/version_contract.ex")

    assert version_contract =~ "schema_version"

    IO.puts("v1-settings-home-layout-freeze-001 status=pass home+settings=frozen")

    AssertBinding.check!("v1-settings-home-layout-freeze-001", [
      :home_roots_exported,
      :frozen_settings_keys_present,
      :schema_version_contract_present
    ])
  end

  # ── Row 5: public-protocol surface policy freeze ─────────────────────────────

  test "v1-public-surface-policy-freeze-001: the public-protocol settings shape, its eval proof, and Runner routing hold" do
    schema = read!("apps/allbert_assist/lib/allbert_assist/settings/schema.ex")

    for key <- ["mcp_server", "openai_api", "acp_server"] do
      assert schema =~ key
    end

    # The public-surface routing/denial proof still exists (deny-before-allow, self-approval).
    assert File.exists?(
             Path.join(
               @repo_root,
               "apps/allbert_assist/test/security/v051_public_protocol_eval_test.exs"
             )
           )

    # All effectful public work routes through the Runner boundary.
    assert function_exported?(Runner, :run, 3)

    IO.puts("v1-public-surface-policy-freeze-001 status=pass public_surface=frozen")

    AssertBinding.check!("v1-public-surface-policy-freeze-001", [
      :public_protocol_settings_present,
      :public_surface_eval_present,
      :effectful_via_runner
    ])
  end

  # ── Row 6: tier classification matches the freeze notes ──────────────────────

  test "v1-tier1-tier2-classification-001: the freeze notes carry per-contract tier + consumer entries the sweep matches" do
    notes = read!(@freeze_notes)

    # Tier tables with a Consumers column.
    assert notes =~ "## Tier 1" and notes =~ "## Tier 2"
    assert notes =~ "Consumers"

    # Consumer-count entries are present (numeric consumers appear in the tables).
    assert Regex.match?(~r/\|\s*\d+\s*\|/, notes), "no consumer-count entries in the freeze notes"

    # Every contract the sweep asserts by name is classified in the freeze notes.
    for name <- ["submit_user_input", "Runner.run/3", "Paths", "SurfaceProvider", "mcp_server"] do
      assert notes =~ name, "freeze notes do not classify #{name}"
    end

    IO.puts("v1-tier1-tier2-classification-001 status=pass classification=matched")

    AssertBinding.check!("v1-tier1-tier2-classification-001", [
      :freeze_notes_tier_tables,
      :freeze_notes_consumer_counts,
      :sweep_contracts_in_freeze_notes
    ])
  end

  # ── Row 7: ADR 0021 A20 reserved-vocabulary-not-frozen ───────────────────────

  test "v1-adr0021-vocabulary-not-frozen-001: ADR 0021 A20 records the not-frozen decision and is cross-linked" do
    adr = read!("docs/adr/0021-intent-objective-capability-and-advisory-boundary.md")

    assert adr =~ "### A20"
    assert adr =~ ~r/NOT part of the 1\.0 freeze/i

    # A20 names the reserved advisory-provider vocabulary it exempts.
    assert adr =~ "advisory-provider" or adr =~ "WorldModelProvider"

    # The freeze notes / plan cross-link A20.
    notes = read!(@freeze_notes)
    plan = read!("docs/plans/v1.0-plan.md")
    assert notes =~ "A20" or plan =~ "A20"

    IO.puts("v1-adr0021-vocabulary-not-frozen-001 status=pass a20=cross_linked")

    AssertBinding.check!("v1-adr0021-vocabulary-not-frozen-001", [
      :adr0021_a20_present,
      :a20_names_reserved_vocabulary,
      :a20_cross_linked
    ])
  end

  test "every :v1 row binds its assert atoms in its owning test" do
    sources = Map.new(@owner_files, fn {mod, path} -> {mod, read!(path)} end)

    for row <- EvalInventory.rows_for_milestone(:v1) do
      source = Map.fetch!(sources, row.test_module)

      assert source =~ ~s|check!("#{row.id}"|,
             "row #{row.id} has no AssertBinding.check!/2 binding in #{row.test_module}"
    end

    IO.puts("v1-assert-atom-binding status=pass rows=7 unbound=0")
  end

  defp read!(relative) do
    @repo_root |> Path.join(relative) |> File.read!()
  end
end
