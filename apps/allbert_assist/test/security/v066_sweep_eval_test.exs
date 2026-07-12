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
  alias AllbertAssist.Actions.Settings.SetNotesRoot
  alias AllbertAssist.CLI.Commands
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
      read!("apps/allbert_assist_web/lib/allbert_assist_web/workspace/components/operator_panels.ex")

    workspace_live = read!("apps/allbert_assist_web/lib/allbert_assist_web/live/workspace_live.ex")

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
