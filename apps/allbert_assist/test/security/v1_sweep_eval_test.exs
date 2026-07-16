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

    # No frozen Tier 1 surface removed: the core Tier 1 anchors still exist by exact name
    # (turn signals, Runtime/Runner entry, Plugin/App behaviours, Resource Access).
    assert function_exported?(Runtime, :submit_user_input, 1)
    assert function_exported?(Runner, :run, 3)
    assert turn_signals_present?()
    assert loaded?(AllbertAssist.Plugin) and loaded?(AllbertAssist.App)
    assert loaded?(AllbertAssist.Resources.ResourceURI)

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
    # The full frozen Home-root set (not a sample) — the freeze locks all root names.
    assert home_roots_present?(), "a frozen Allbert Home root was renamed/removed"

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

    # Default-off exposure is frozen (the public surfaces ship disabled by default).
    assert schema =~ ~s("enabled" => false),
           "public-protocol default-off exposure ('enabled' => false) is missing"

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

    # Real reconciliation: EVERY contract the sweep enforces is classified in the freeze
    # notes (not just a hand-picked few) — so the sweep's contract set matches the notes.
    unclassified =
      frozen_contracts()
      |> Enum.reject(fn {_label, anchor, _check} -> notes =~ anchor end)
      |> Enum.map(fn {label, _, _} -> label end)

    assert unclassified == [],
           "sweep enforces contracts the freeze notes do not classify: #{inspect(unclassified)}"

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
    plan = read!("docs/plans/archives/v1.0-plan.md")
    assert notes =~ "A20" or plan =~ "A20"

    IO.puts("v1-adr0021-vocabulary-not-frozen-001 status=pass a20=cross_linked")

    AssertBinding.check!("v1-adr0021-vocabulary-not-frozen-001", [
      :adr0021_a20_present,
      :a20_names_reserved_vocabulary,
      :a20_cross_linked
    ])
  end

  # ── Comprehensive coverage: every frozen contract exists by exact name ───────
  #
  # M2.1 remediation (post-implementation audit Finding 1): the 7 rows above proved a
  # representative subset. `frozen_contracts/0` is the CANONICAL list of every frozen
  # Tier 1/Tier 2 contract with its exact-name check, so a rename/removal of ANY frozen
  # contract fails release.v1 — and the reconciliation test below fails if the freeze
  # notes and this list ever diverge (so the coverage gap cannot recur).

  defp frozen_contracts do
    [
      # Tier 1
      {"Runtime.submit_user_input/1", "submit_user_input",
       fn -> exported?(Runtime, :submit_user_input, 1) end},
      {"turn signals", "allbert.input.received", &turn_signals_present?/0},
      {"Actions.Registry", "Actions.Registry", fn -> exported?(ActionsRegistry, :names, 0) end},
      {"Actions.Runner.run/3", "Runner.run/3", fn -> exported?(Runner, :run, 3) end},
      {":invalid_params shape", "invalid_params",
       fn ->
         src?("apps/allbert_assist/lib/allbert_assist/actions/runner.ex", ":invalid_params")
       end},
      {"Policy.permission_classes/0", "Permission classes",
       fn -> exported?(Policy, :permission_classes, 0) end},
      {"Plugin behaviour", "AllbertAssist.Plugin", fn -> loaded?(AllbertAssist.Plugin) end},
      {"App behaviour", "AllbertAssist.App`", fn -> loaded?(AllbertAssist.App) end},
      {"schema_version contract", "schema_version",
       fn ->
         src?(
           "apps/allbert_assist/lib/allbert_assist/settings/version_contract.ex",
           "schema_version"
         )
       end},
      {"Home roots (Paths)", "Paths", &home_roots_present?/0},
      {"conversation_threads.id", "conversation_threads.id",
       fn -> loaded?(Thread) and :id in Thread.__schema__(:fields) end},
      {"channel identity columns", "provider_thread_key", &channel_columns_present?/0},
      {"ResourceURI", "ResourceURI", fn -> loaded?(AllbertAssist.Resources.ResourceURI) end},
      {"operation classes", "operation classes",
       fn -> exported?(AllbertAssist.Resources.OperationClass, :operation_classes, 0) end},
      {"grant shape", "grant shape", fn -> loaded?(AllbertAssist.Resources.Grant) end},
      {"model/provider doctor shape (ADR 0047)", "doctor return shape",
       fn -> loaded?(AllbertAssist.Actions.Settings.Doctor) end},
      {"installer cosign fail-closed", "cosign",
       fn -> src?("scripts/install/install.sh", "cosign") end},
      # Tier 2
      {"App.SurfaceProvider", "SurfaceProvider",
       fn -> loaded?(AllbertAssist.App.SurfaceProvider) end},
      {"Fragment envelope", "Fragment envelope",
       fn -> loaded?(AllbertAssist.Workspace.Fragment.Envelope) end},
      {"Workspace canvas", "canvas", fn -> loaded?(AllbertAssist.Workspace.Canvas) end},
      {"Workspace ephemeral", "ephemeral", fn -> loaded?(AllbertAssist.Workspace.Ephemeral) end},
      {"SignalBridge", "SignalBridge",
       fn ->
         src?("apps/allbert_assist_web/lib/allbert_assist_web/signal_bridge.ex", "defmodule")
       end},
      {"Templates", "AllbertAssist.Templates", fn -> loaded?(AllbertAssist.Templates) end},
      {"Templates.Pattern", "Templates.Pattern",
       fn -> loaded?(AllbertAssist.Templates.Pattern) end},
      {"template actions", "render_template",
       fn ->
         Enum.all?(
           ~w(render_template validate_template scaffold_template create_from_template),
           &registered?/1
         )
       end},
      {"workspace:create destination", "workspace:create",
       fn ->
         src?("apps/allbert_assist/lib/allbert_assist/workspace/catalog.ex", "workspace:create")
       end},
      {"template Settings keys", "templates.create.enabled",
       fn ->
         schema_has?("templates.create.enabled") and schema_has?("templates.allowed_patterns")
       end},
      {"public-protocol Settings", "mcp_server",
       fn -> Enum.all?(~w(mcp_server openai_api acp_server), &schema_has?/1) end},
      {"CLI operator_table", "operator_table",
       fn -> exported?(AllbertAssist.CLI.Commands, :operator_table, 0) end},
      {"secret Vault + token_ref", "token_ref", fn -> loaded?(AllbertAssist.Settings.Vault) end},
      {"/health shape", "/health",
       fn ->
         src?("apps/allbert_assist_web/lib/allbert_assist_web/router.ex", ~s(get "/health"))
       end},
      {"attach-over-UDS handshake", "Attach", fn -> loaded?(AllbertAssist.Runtime.Attach) end},
      {"notes_files actions", "search_notes",
       fn -> Enum.all?(~w(search_notes read_note write_note), &registered?/1) end},
      {"set_notes_root + key", "apps.notes_files.notes_root",
       fn ->
         exported?(AllbertAssist.Actions.Settings.SetNotesRoot, :capability, 0) and
           src?(
             "apps/allbert_assist/lib/allbert_assist/actions/settings/set_notes_root.ex",
             "apps.notes_files.notes_root"
           )
       end},
      {"memory review-status vocabulary", ":prune_nominated",
       fn ->
         src = read!("apps/allbert_assist/lib/allbert_assist/memory.ex")
         Enum.all?([":unreviewed", ":kept", ":flagged", ":prune_nominated"], &(src =~ &1))
       end}
    ]
  end

  test "every frozen contract exists by exact name (comprehensive freeze enforcement)" do
    missing =
      frozen_contracts()
      |> Enum.reject(fn {_label, _anchor, check} -> check.() end)
      |> Enum.map(fn {label, _anchor, _check} -> label end)

    assert missing == [],
           "frozen contracts renamed/removed (freeze broken): #{inspect(missing)}"

    IO.puts("v1-frozen-contracts-present status=pass frozen=#{length(frozen_contracts())}")
  end

  test "the freeze notes classify every frozen contract the sweep enforces (reconciliation)" do
    notes = read!(@freeze_notes)

    undocumented =
      frozen_contracts()
      |> Enum.reject(fn {_label, anchor, _check} -> notes =~ anchor end)
      |> Enum.map(fn {label, anchor, _} -> "#{label} (anchor #{inspect(anchor)})" end)

    assert undocumented == [],
           "frozen contracts enforced but not classified in the freeze notes: #{inspect(undocumented)}"

    IO.puts("v1-freeze-notes-reconciliation status=pass frozen=#{length(frozen_contracts())}")
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

  # ── exact-name check helpers ─────────────────────────────────────────────────

  defp loaded?(mod), do: Code.ensure_loaded?(mod)

  defp exported?(mod, fun, arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)

  defp registered?(name), do: name in ActionsRegistry.names()

  defp schema_has?(key),
    do: src?("apps/allbert_assist/lib/allbert_assist/settings/schema.ex", key)

  defp src?(relative, str), do: read!(relative) =~ str

  @turn_signals ~w(
    allbert.input.received
    allbert.agent.responded
    allbert.runtime.turn.started
    allbert.runtime.turn.completed
  )
  defp turn_signals_present? do
    src =
      read!("apps/allbert_assist/lib/allbert_assist/signals.ex") <>
        read!("apps/allbert_assist/lib/allbert_assist/runtime.ex")

    Enum.all?(@turn_signals, &(src =~ &1))
  end

  # The frozen Allbert Home roots (the full set the freeze locks, not a sample).
  @home_roots ~w(settings_root memory_root memory_deleted_root artifacts_root audio_root
    images_root confirmations_root execution_root package_installs_root sandbox_root
    dynamic_plugins_root drafts_root external_root mcp_root db_path)a
  defp home_roots_present? do
    Enum.all?(@home_roots, &exported?(Paths, &1, 0))
  end

  defp channel_columns_present? do
    fields = loaded?(ThreadChannelRef) and ThreadChannelRef.__schema__(:fields)

    is_list(fields) and
      Enum.all?([:owner_scope, :receiver_account_ref, :provider_thread_key], &(&1 in fields))
  end

  defp read!(relative) do
    @repo_root |> Path.join(relative) |> File.read!()
  end
end
