defmodule AllbertAssist.Security.V066SweepEvalTest do
  @moduledoc """
  v0.66 Product RC & No-Docs Validation sweep.

  This sweep owns every gate-bound / mixed `product-rc-*` eval row (the
  attested-only ids live in the `docs/validation/v0.66/` evidence matrix, not the
  inventory). Each row is a contract-level proxy (plan Locked Decision 2): it
  asserts capability exposure, permission/confirmation floors, routing decisions,
  and boundary contracts against the already-shipped v0.61-v0.65 surfaces — never
  live browser/model/provider behavior. Every proof calls `AssertBinding.check!/2`
  so the inventory `assert:` atoms stay attached to a real assertion, and the
  meta-tests keep the row set complete, shaped, routed, and bound.

  The sweep is built milestone-by-milestone: `@eval_ids` grows as each v0.66
  milestone lands its row, so the completeness meta-test tracks exactly the rows
  that exist at each commit (no magic number until M11 finalizes the full set).
  """
  use AllbertAssist.SecurityEvalCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Memory.ReviewMemoryEntry
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Actions.Settings.ApplyPersonaProfile
  alias AllbertAssist.Actions.Settings.SetNotesRoot
  alias AllbertAssist.CLI.Commands
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Portability.Import, as: PortabilityImport
  alias AllbertAssist.Portability.SecretReferences
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertNotesFiles.Actions.ReadNote
  alias AllbertNotesFiles.Actions.SearchNotes
  alias AllbertNotesFiles.Actions.WriteNote

  @repo_root Path.expand("../../../../", __DIR__)

  # Grows one milestone at a time (M3 web-smoke -> ... -> M11 finalize).
  @eval_ids ~w(
    product-rc-web-smoke-no-console-error-001
    product-rc-cli-tui-no-mix-needed-001
    product-rc-local-files-notes-memory-policy-bounded-001
    product-rc-advanced-surfaces-no-regression-001
    product-rc-conversational-routing-no-misroute-001
    product-rc-consumer-default-oneclick-model-no-key-first-chat-001
    product-rc-profile-no-authority-regression-001
    product-rc-packaging-no-authority-regression-001
    product-rc-export-import-upgrade-001
    product-rc-evidence-secret-scan-001
    product-rc-v1-handoff-current-001
  )

  @owner "AllbertAssist.Security.V066SweepEvalTest"
  @owners Map.new(@eval_ids, &{&1, @owner})
  @owner_files %{@owner => "apps/allbert_assist/test/security/v066_sweep_eval_test.exs"}

  test "v0.66 eval inventory rows are complete and routed to their owning test" do
    rows = EvalInventory.rows_for_milestone(:v066)
    row_ids = Enum.map(rows, & &1.id)
    rows_by_id = Map.new(rows, &{&1.id, &1})

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.milestone == :v066))

    for {id, owner} <- @owners do
      assert rows_by_id[id].test_module == owner, "row #{id} routed to the wrong owning test"
    end

    IO.puts("v066-inventory-complete status=pass rows=#{length(row_ids)} owners=routed")
  end

  test "v0.66 rows encode concrete pass criteria" do
    rows = EvalInventory.rows_for_milestone(:v066)

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert) and length(row.assert) >= 3
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
    end
  end

  # ── M3: browser web smoke (render/dispatch contract) ─────────────────────────

  test "product-rc-web-smoke-no-console-error-001: the web shell renders behind the browser pipeline and its panels stay action-backed" do
    router = read!("apps/allbert_assist_web/lib/allbert_assist_web/router.ex")

    panels =
      read!(
        "apps/allbert_assist_web/lib/allbert_assist_web/workspace/components/operator_panels.ex"
      )

    workspace_live =
      read!("apps/allbert_assist_web/lib/allbert_assist_web/live/workspace_live.ex")

    # The workspace/jobs/objectives routes render through LiveViews behind the
    # :browser pipeline, the landing is a controller page, and /health is exposed —
    # the routes the browser smoke and the item-11 usability audit exercise.
    assert router =~ ~s|live "/workspace", WorkspaceLive|
    assert router =~ ~s|live "/jobs", JobsLive|
    assert router =~ ~s|live "/objectives", ObjectivesLive|
    assert router =~ ~s|get "/", PageController, :home|
    assert router =~ ~s|get "/health", HealthController, :show|

    # Operator panels (onboarding/settings/notes/memory) dispatch registered actions
    # through the Runner — the render path never grants authority by itself.
    assert panels =~ ~s|Runner.run("review_memory_entry"|
    assert panels =~ ~s|Runner.run("delete_memory_entry"|
    assert panels =~ ~s|Runner.run("read_note"|

    # The workspace shell never reads Settings/Confirmations/Repo stores directly —
    # a render that bypassed the action boundary is the leak this row guards.
    refute workspace_live =~ "Settings.get("
    refute workspace_live =~ "Confirmations.list("
    refute workspace_live =~ "Repo."

    IO.puts("product-rc-web-smoke-no-console-error-001 status=pass render=pipeline_bound")

    AssertBinding.check!("product-rc-web-smoke-no-console-error-001", [
      :live_routes_registered,
      :operator_panels_action_backed,
      :no_direct_store_render
    ])
  end

  # ── M4: CLI / TUI dispatch contract (no raw mix for operator work) ────────────

  test "product-rc-cli-tui-no-mix-needed-001: operator verbs run in the binary, admin reads route through actions, dev commands stay under mix" do
    table = Commands.operator_table()

    # The core operator verbs are packaged-binary entry points, never :mix_only —
    # a non-developer never needs raw `mix` to serve/onboard/ask/chat/tui.
    operator_verbs = [["ask"], ["chat"], ["tui"], ["serve"], ["onboard"]]

    for path <- operator_verbs do
      assert {:ok, disposition} = Commands.lookup(path)
      refute disposition == :mix_only, "operator verb #{inspect(path)} is :mix_only"
    end

    # Admin reads dispatch through registered actions ({:action, name}) — the read
    # goes through the action boundary, not a raw store read from the CLI.
    for {path, action} <- [
          {["admin", "status"], "operator_status"},
          {["admin", "health"], "serve_health"},
          {["admin", "events"], "operator_events"}
        ] do
      assert Commands.lookup(path) == {:ok, {:action, action}}
    end

    # Development/CI generators stay :mix_only — they are not exposed as operator
    # surface in the packaged binary.
    assert Commands.lookup(["gen"]) == {:ok, :mix_only}
    assert Enum.any?(table, fn {_path, disp} -> disp == :mix_only end)

    IO.puts("product-rc-cli-tui-no-mix-needed-001 status=pass split=operator_vs_mix")

    AssertBinding.check!("product-rc-cli-tui-no-mix-needed-001", [
      :operator_verbs_not_mix_only,
      :admin_reads_route_through_actions,
      :dev_commands_isolated_to_mix
    ])
  end

  # ── M5: local files/notes/memory launch-path policy floors ───────────────────

  test "product-rc-local-files-notes-memory-policy-bounded-001: the launch-path actions keep their permission/confirmation floors" do
    # Notes reads are read-only — the launch integration never grants mutation
    # authority through a read.
    assert SearchNotes.capability().permission == :read_only
    assert ReadNote.capability().permission == :read_only

    # write_note stays confirmation-gated with its own write permission — a note the
    # agent writes always pauses for explicit operator approval.
    assert WriteNote.capability().confirmation == :required
    assert WriteNote.capability().permission == :notes_file_write

    # Connecting a notes root and reviewing memory carry their existing settings/
    # memory-write authority, not a broad or new grant.
    assert SetNotesRoot.capability().permission == :settings_write
    assert ReviewMemoryEntry.capability().permission == :memory_write

    IO.puts("product-rc-local-files-notes-memory-policy-bounded-001 status=pass floors=intact")

    AssertBinding.check!("product-rc-local-files-notes-memory-policy-bounded-001", [
      :notes_reads_read_only,
      :write_note_confirmation_gated,
      :memory_review_permissioned
    ])
  end

  # ── M6: advanced-surface regression (capability exposure boundary) ───────────

  test "product-rc-advanced-surfaces-no-regression-001: internal capabilities stay internal and advanced surfaces stay registered" do
    agent_names = ActionsRegistry.agent_capabilities() |> Enum.map(& &1.name) |> MapSet.new()

    internal_names =
      ActionsRegistry.internal_capabilities() |> Enum.map(& &1.name) |> MapSet.new()

    # Internal actions are held internal — not every action is agent/public-exposed.
    assert MapSet.size(internal_names) > 0

    # The agent-exposed set and the internal set never overlap — an advanced surface
    # cannot leak an internal capability onto the agent/public protocol surface.
    assert MapSet.disjoint?(agent_names, internal_names)

    # Representative advanced-surface actions stay registered across their classes:
    # public protocol, remote channels, and MCP.
    names = MapSet.new(ActionsRegistry.names())
    assert MapSet.member?(names, "create_protocol_token")
    assert MapSet.member?(names, "send_channel_message")
    assert MapSet.member?(names, "mcp_list_tools")

    IO.puts("product-rc-advanced-surfaces-no-regression-001 status=pass exposure=disjoint")

    AssertBinding.check!("product-rc-advanced-surfaces-no-regression-001", [
      :internal_capabilities_held_internal,
      :agent_internal_exposure_disjoint,
      :advanced_surface_actions_registered
    ])
  end

  # ── M7: consumer-default first-chat + conversational routing quality ─────────

  test "product-rc-conversational-routing-no-misroute-001: launch-path memory phrasings route to a candidate instead of stalling on a missing slot" do
    assert {:ok, descriptor} =
             Descriptor.normalize(%{
               app_id: :allbert,
               action_name: "append_memory",
               label: "Remember a fact in memory",
               required_slots: [:memory],
               slot_extractors: %{memory: :memory_phrase}
             })

    # "remember X" extracts the memory content — no missing slot, so the intent
    # routes to a reviewable candidate instead of a needs-clarification stall.
    remember = Descriptor.extract_slots(descriptor, "remember I prefer aisle seats")
    assert remember == %{extracted_slots: %{memory: "I prefer aisle seats"}, missing_slots: []}

    # "note to self: X" routes the same way (the other launch-path write phrasing).
    note = Descriptor.extract_slots(descriptor, "note to self: the retro is every Friday")
    assert note == %{extracted_slots: %{memory: "the retro is every Friday"}, missing_slots: []}

    # The class guard: neither phrasing leaves a required slot missing (the v0.63 F5 /
    # v0.65 mis-route-to-clarification bug class stays fixed).
    assert remember.missing_slots == []
    assert note.missing_slots == []

    IO.puts("product-rc-conversational-routing-no-misroute-001 status=pass route=no_stall")

    AssertBinding.check!("product-rc-conversational-routing-no-misroute-001", [
      :memory_write_phrase_no_stall,
      :note_to_self_phrase_routes,
      :no_missing_slot_misroute
    ])
  end

  test "product-rc-consumer-default-oneclick-model-no-key-first-chat-001: the consumer-default first-model path is keyless-local, with BYOK as the fallback" do
    # A ready local model resolves keyless-ready — the consumer default reaches a
    # usable model with no API key.
    assert FirstRun.first_model_state(ollama_probe: fn -> :model_ready end) == :local_ready

    # No local model and no provider key guides the operator to runtime setup
    # (:runtime_missing), it never demands a key to proceed.
    assert FirstRun.first_model_state(
             ollama_probe: fn -> :missing end,
             byok_ready?: fn -> false end
           ) ==
             :runtime_missing

    # BYOK is the advanced fallback: a provider key with no local runtime resolves
    # :byok_ready, distinct from the default keyless-local path.
    assert FirstRun.first_model_state(
             ollama_probe: fn -> :missing end,
             byok_ready?: fn -> true end
           ) ==
             :byok_ready

    IO.puts(
      "product-rc-consumer-default-oneclick-model-no-key-first-chat-001 status=pass path=keyless_local"
    )

    AssertBinding.check!("product-rc-consumer-default-oneclick-model-no-key-first-chat-001", [
      :local_ready_keyless,
      :no_key_demand_when_runtime_missing,
      :byok_is_advanced_fallback
    ])
  end

  # ── M8: cross-surface no-authority delta-sweep (fully gate-provable) ──────────

  test "product-rc-profile-no-authority-regression-001: applying a persona profile writes only settings, stays gated and internal, and adds no permission class" do
    capability = ApplyPersonaProfile.capability()

    # Profiles seed settings only — no broad or new grant.
    assert capability.permission == :settings_write

    # The apply stays confirmation-gated and setup-time internal (never an agent tool),
    # so a persona can't be applied to escalate authority.
    assert capability.confirmation == :required
    assert capability.exposure == :internal

    # :settings_write is an existing permission class — profiles introduce none.
    assert :settings_write in Policy.permission_classes()

    IO.puts("product-rc-profile-no-authority-regression-001 status=pass authority=none")

    AssertBinding.check!("product-rc-profile-no-authority-regression-001", [
      :profile_apply_settings_scoped,
      :profile_apply_confirmation_gated_internal,
      :profile_apply_no_new_class
    ])
  end

  test "product-rc-packaging-no-authority-regression-001: the whole registry stays within the known permission classes and packaged reads stay internal" do
    classes = MapSet.new(Policy.permission_classes())
    assert MapSet.size(classes) > 0

    # No surface (packaging, onboarding, notes/memory, advanced) introduces a new
    # permission class: every registered capability reuses an existing class.
    unknown =
      ActionsRegistry.capabilities()
      |> Enum.reject(&MapSet.member?(classes, &1.permission))
      |> Enum.map(& &1.name)

    assert unknown == [], "actions with an unknown permission class: #{inspect(unknown)}"

    # Representative packaged operator reads stay internal and off the intent router.
    agent_names = ActionsRegistry.agent_capabilities() |> Enum.map(& &1.name) |> MapSet.new()

    for name <- ["serve_health", "operator_status"] do
      assert {:ok, cap} = ActionsRegistry.capability(name)
      assert cap.exposure == :internal, "#{name} must stay internal"
      refute MapSet.member?(agent_names, name), "#{name} must not be agent-routable"
    end

    IO.puts("product-rc-packaging-no-authority-regression-001 status=pass new_classes=0")

    AssertBinding.check!("product-rc-packaging-no-authority-regression-001", [
      :registry_permissions_all_known,
      :packaged_reads_internal,
      :permission_class_set_stable
    ])
  end

  # ── M9: Home portability (export redaction + import dry-run) ─────────────────

  test "product-rc-export-import-upgrade-001: exports carry secret ref+status not values, and import is a dry-run that blocks before applying" do
    # A settings structure carrying a secret reference exports as ref + status only —
    # the raw secret value is never fetched or embedded.
    settings = %{
      "providers" => %{"openai" => %{"api_key" => "secret://providers/openai/api_key"}}
    }

    rows = SecretReferences.export_rows(settings)
    assert is_list(rows) and rows != []

    for row <- rows do
      assert Map.has_key?(row, "ref")
      assert Map.has_key?(row, "status")
      # Only the reference URI and a status token travel — never a raw value.
      assert row["ref"] =~ "secret://"
      refute Map.has_key?(row, "value")
    end

    # Importing an Allbert Home is a dry-run that blocks before applying any change —
    # a missing/invalid envelope path still returns a dry-run diagnostic, never a write.
    missing =
      Path.join(System.tmp_dir!(), "v066-missing-#{System.unique_integer([:positive])}.json")

    assert {:error, diag} = PortabilityImport.dry_run(missing)
    assert diag["dry_run"] == true

    IO.puts("product-rc-export-import-upgrade-001 status=pass portability=dry_run_redacted")

    AssertBinding.check!("product-rc-export-import-upgrade-001", [
      :secret_refs_exported_not_values,
      :import_is_dry_run,
      :import_blocks_before_apply
    ])
  end

  # ── M11: evidence secret scan + v1.0 handoff currency ────────────────────────

  test "product-rc-evidence-secret-scan-001: redaction removes secret values and refs while keeping public fields" do
    # A secret key's value is redacted before it can reach a log, output, or evidence file.
    redacted = Redactor.redact(%{"api_key" => "sk-DO-NOT-LEAK-123", "note" => "public detail"})
    assert redacted["api_key"] == "[REDACTED]"
    refute redacted["api_key"] =~ "sk-"

    # A secret reference URI is redacted to a marker, never surfaced raw.
    assert Redactor.redact("secret://providers/openai/api_key") == "[SECRET_REF]"

    # Non-secret fields survive so the evidence stays useful.
    assert redacted["note"] == "public detail"

    IO.puts("product-rc-evidence-secret-scan-001 status=pass redaction=secrets_only")

    AssertBinding.check!("product-rc-evidence-secret-scan-001", [
      :secret_key_value_redacted,
      :secret_ref_redacted,
      :public_fields_preserved
    ])
  end

  test "product-rc-v1-handoff-current-001: the v1.0 handoff note and its 17-item acceptance matrix are current" do
    handoff = read!("docs/plans/archives/v1.0-handoff.md")
    roadmap = read!("docs/plans/roadmap.md")

    # The handoff note exists and frames the acceptance matrix (case-insensitive, so it
    # survives heading rewording — e.g. a "proof-status view" reframe).
    assert handoff =~ ~r/acceptance matrix/i

    # The substance is the 17 numbered acceptance rows themselves — asserted directly by
    # count rather than a prose "17-item" literal, so the v0.66 gate does not break when
    # the v1.0 handoff heading/intro is reworded.
    matrix_rows =
      handoff
      |> String.split("\n")
      |> Enum.filter(&Regex.match?(~r/^\| \d+ \|/, &1))

    assert length(matrix_rows) == 17, "expected 17 acceptance rows, got #{length(matrix_rows)}"

    # The roadmap still names the v0.66 RC and the v1.0 freeze the handoff points to.
    assert roadmap =~ "v0.66"
    assert roadmap =~ "v1.0" and roadmap =~ "freeze"

    IO.puts("product-rc-v1-handoff-current-001 status=pass handoff=current rows=17")

    AssertBinding.check!("product-rc-v1-handoff-current-001", [
      :v1_handoff_note_present,
      :acceptance_matrix_seventeen_inputs,
      :roadmap_names_rc_and_v1_freeze
    ])
  end

  # The v0.66 sweep is the cross-surface delta-sweep the plan (M8) names: its rows span
  # the surfaces added since the v0.59 M4 sweep — landing/web (M3), packaged CLI (M4),
  # notes/memory (M5), advanced surfaces (M6), onboarding/routing/first-model (M7), and
  # profile/packaging authority (M8) — each bound to an owning assertion below.
  test "the v0.66 delta-sweep covers the product-RC surface classes since v0.59" do
    surfaces =
      EvalInventory.rows_for_milestone(:v066)
      |> Enum.map(& &1.boundary)
      |> MapSet.new()

    for boundary <- [
          :render_dispatch_contract,
          :cli_dispatch_contract,
          :permission_floor,
          :capability_exposure,
          :intent_routing,
          :first_model_state,
          :no_new_authority
        ] do
      assert MapSet.member?(surfaces, boundary), "delta-sweep missing #{boundary} coverage"
    end

    IO.puts("v066-delta-sweep-coverage status=pass surface_classes=#{MapSet.size(surfaces)}")
  end

  test "every :v066 row binds its assert atoms in its owning test" do
    sources = Map.new(@owner_files, fn {mod, path} -> {mod, read!(path)} end)

    for row <- EvalInventory.rows_for_milestone(:v066) do
      source = Map.fetch!(sources, row.test_module)

      assert source =~ ~s|check!("#{row.id}"|,
             "row #{row.id} has no AssertBinding.check!/2 binding in #{row.test_module}"
    end

    IO.puts("v066-assert-atom-binding status=pass unbound=0")
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp read!(relative) do
    @repo_root |> Path.join(relative) |> File.read!()
  end
end
