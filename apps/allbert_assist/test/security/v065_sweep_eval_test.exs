defmodule AllbertAssist.Security.V065SweepEvalTest do
  @moduledoc """
  v0.65 Local Knowledge: Files, Notes, And Agent Memory sweep.

  This sweep owns all thirteen `:v065` eval rows. Each behavioural row is proved
  against the already-built v0.65 surfaces/actions (the `set_notes_root` connect
  affordance, `allbert admin notes set-root`, notes root/extension bounding, the
  confirmation-gated `write_note`, the non-writable `:notes_files` memory
  namespace, the reviewed-memory keep/reject/delete loop, `review_status_counts`,
  and `:kept`-only recall). Every proof calls `AssertBinding.check!/2` so the
  inventory `assert:` atoms stay attached to a real assertion, and the meta-tests
  keep the row inventory complete, routed, and bound.
  """
  use AllbertAssist.SecurityEvalCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Memory.DeleteMemoryEntry
  alias AllbertAssist.Actions.Memory.ReviewMemoryEntry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Actions.Settings.SetNotesRoot
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.CLI.Areas.Notes, as: NotesArea
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.ActiveMemory
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertNotesFiles.Actions.WriteNote

  @now "2026-05-28T12:00:00Z"

  @eval_ids ~w(
    local-knowledge-notes-root-explicit-001
    local-knowledge-connect-affordance-config-free-001
    local-knowledge-admin-notes-set-root-001
    local-knowledge-quickstart-connect-reachable-001
    local-knowledge-read-scoped-001
    local-knowledge-write-confirmed-001
    local-knowledge-no-auto-memory-promotion-001
    local-knowledge-memory-review-user-controlled-001
    local-knowledge-review-panel-no-authority-001
    local-knowledge-memory-reject-flagged-001
    local-knowledge-memory-status-001
    local-knowledge-recall-reviewed-memory-001
    local-knowledge-v066-handoff-current-001
  )

  @owner "AllbertAssist.Security.V065SweepEvalTest"

  @owners Map.new(@eval_ids, &{&1, @owner})

  @owner_files %{
    @owner => "apps/allbert_assist/test/security/v065_sweep_eval_test.exs"
  }

  @repo_root Path.expand("../../../../", __DIR__)

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_confirmations = Application.get_env(:allbert_assist, Confirmations)
    original_plugins = PluginRegistry.registered_plugins()
    notes_app_registered? = AppRegistry.known_app_id?(:notes_files)

    home =
      Path.join(System.tmp_dir!(), "allbert-v065-sweep-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Memory, root: Path.join(home, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(home, "confirmations"))

    PluginRegistry.clear()
    assert {:ok, "allbert.notes_files"} = PluginRegistry.register_module(AllbertNotesFiles.Plugin)

    unless notes_app_registered? do
      assert {:ok, :notes_files} = AppRegistry.register(AllbertNotesFiles.App)
    end

    notes_root = Path.join(home, "launch-notes")
    File.mkdir_p!(notes_root)

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Memory, original_memory)
      restore_env(Settings, original_settings)
      restore_env(Confirmations, original_confirmations)
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
      unless notes_app_registered?, do: AppRegistry.unregister(:notes_files)
      File.rm_rf!(home)
    end)

    {:ok, home: home, notes_root: notes_root}
  end

  test "v0.65 eval inventory rows are complete and routed to their owning test" do
    rows = EvalInventory.rows_for_milestone(:v065)
    row_ids = Enum.map(rows, & &1.id)
    rows_by_id = Map.new(rows, &{&1.id, &1})

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert length(row_ids) == 13
    assert Enum.all?(rows, &(&1.milestone == :v065))

    for {id, owner} <- @owners do
      assert rows_by_id[id].test_module == owner, "row #{id} routed to the wrong owning test"
    end

    IO.puts("v065-inventory-complete status=pass rows=13 owners=routed")
  end

  test "v0.65 rows encode concrete pass criteria" do
    rows = EvalInventory.rows_for_milestone(:v065)

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert) and row.assert != []
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
    end
  end

  test "local-knowledge-notes-root-explicit-001: the notes root is one explicit safe key" do
    dir = Path.join(System.tmp_dir!(), "notes-explicit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, response} = SetNotesRoot.run(%{path: dir}, action_context())
    assert response.status == :completed
    # The write lands on the single Settings Central safe key, not a broad grant.
    assert response.setting.key == "apps.notes_files.notes_root"

    # The explicit key reads back through Settings Central.
    assert {:ok, value} = Settings.get("apps.notes_files.notes_root")
    assert value == dir

    IO.puts("local-knowledge-notes-root-explicit-001 status=pass key=single_safe")

    AssertBinding.check!("local-knowledge-notes-root-explicit-001", [
      :notes_root_explicit,
      :single_safe_key,
      :reads_back
    ])
  end

  test "local-knowledge-connect-affordance-config-free-001: connect is a validated action" do
    # The connect affordance carries the existing :settings_write class, no new authority.
    assert SetNotesRoot.capability().permission == :settings_write

    dir = Path.join(System.tmp_dir!(), "notes-connect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # A valid directory connects through the action (no hand-edited config file).
    assert {:ok, ok} = SetNotesRoot.run(%{path: dir}, action_context())
    assert ok.status == :completed

    # The action validates the path and fails closed on a non-directory — the config-free
    # affordance never silently writes a broken root.
    missing = Path.join(System.tmp_dir!(), "nope-#{System.unique_integer([:positive])}")
    assert {:ok, denied} = SetNotesRoot.run(%{path: missing}, action_context())
    assert denied.status == :denied

    IO.puts("local-knowledge-connect-affordance-config-free-001 status=pass path=action")

    AssertBinding.check!("local-knowledge-connect-affordance-config-free-001", [
      :connect_via_action,
      :path_validated,
      :no_manual_config_edit
    ])
  end

  test "local-knowledge-admin-notes-set-root-001: admin notes set-root persists and fails closed",
       %{notes_root: notes_root} do
    assert {out, 0} = NotesArea.dispatch(["set-root", notes_root])
    assert out =~ "Notes root set to"

    assert {shown, 0} = NotesArea.dispatch(["show"])
    assert shown =~ notes_root

    missing = Path.join(notes_root, "does-not-exist")
    assert {denied, 1} = NotesArea.dispatch(["set-root", missing])
    assert denied =~ "could not set the notes root"

    IO.puts("local-knowledge-admin-notes-set-root-001 status=pass cli=admin_notes")

    AssertBinding.check!("local-knowledge-admin-notes-set-root-001", [
      :admin_notes_set_root,
      :set_root_reads_back,
      :missing_dir_fails_closed
    ])
  end

  test "local-knowledge-quickstart-connect-reachable-001: connect renders on the first_chat step" do
    # QuickStart defers only `optional_connect`, so `first_chat` is in its track.
    quickstart_steps = Onboarding.wizard_steps() -- ["optional_connect"]
    assert "first_chat" in quickstart_steps

    # The web onboarding component renders the config-free connect affordance under the
    # `first_chat` step controls — reachable for QuickStart before optional_connect defers.
    onboarding_web =
      read!("apps/allbert_assist_web/lib/allbert_assist_web/workspace/components/onboarding.ex")

    assert onboarding_web =~ ~s|render_step_controls(%{onboarding_wizard: %{step: "first_chat"}}|
    assert onboarding_web =~ "Connect a notes folder"
    assert onboarding_web =~ ~s|phx-submit="connect_notes_root"|
    assert onboarding_web =~ ~s|run_action("set_notes_root"|

    IO.puts("local-knowledge-quickstart-connect-reachable-001 status=pass step=first_chat")

    AssertBinding.check!("local-knowledge-quickstart-connect-reachable-001", [
      :connect_on_first_chat_step,
      :reachable_quickstart_track
    ])
  end

  test "local-knowledge-read-scoped-001: reads stay bounded to the notes root with provenance",
       %{notes_root: notes_root} do
    connect_notes!(notes_root)

    File.write!(
      Path.join(notes_root, "launch.md"),
      "# Launch Note\n\nGrounded local-knowledge note for the read-scoped eval.\n"
    )

    # A note inside the root reads back through the registered action and emits a
    # provenance resource ref.
    assert {:ok, %{status: :completed} = read} =
             Runner.run("read_note", %{path: "launch.md"}, action_context())

    assert read.note.body =~ "Grounded local-knowledge note"
    assert is_list(read.resource_refs) and read.resource_refs != []
    assert get_in(read, [:runner_metadata, :action_capability, :app_id]) == :notes_files

    # A path outside the configured root is denied by root/extension path bounding.
    outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm_rf!(outside) end)
    File.write!(outside, "# Secret\n\nMust never be reachable through the notes root.\n")

    assert {:ok, denied} = Runner.run("read_note", %{path: outside}, action_context())
    assert denied.status in [:denied, :error]
    assert denied.message =~ "path_outside_notes_root"

    IO.puts("local-knowledge-read-scoped-001 status=pass bounding=root_extension")

    AssertBinding.check!("local-knowledge-read-scoped-001", [
      :read_bounded_to_root,
      :path_outside_root_denied,
      :notes_files_active_app_scope,
      :resource_ref_provenance
    ])
  end

  test "local-knowledge-write-confirmed-001: write_note keeps its confirmation floor" do
    capability = WriteNote.capability()

    assert capability.confirmation == :required
    assert capability.permission == :notes_file_write

    IO.puts("local-knowledge-write-confirmed-001 status=pass write=confirmation_gated")

    AssertBinding.check!("local-knowledge-write-confirmed-001", [
      :write_requires_confirmation,
      :notes_file_write_permission
    ])
  end

  test "local-knowledge-no-auto-memory-promotion-001: candidates are unreviewed and notes never write memory" do
    # New memory candidates default to :unreviewed — nothing is recallable on creation.
    assert {:ok, entry} = append("alice", "A stray candidate the agent proposed.")
    assert entry.review_status == :unreviewed

    # The :notes_files memory namespace is non-writable: notes cannot auto-promote to memory.
    assert {:error, {:memory_namespace_not_writable, :notes_files}} =
             Memory.upsert_app_entry(%{
               app_id: :notes_files,
               namespace: :notes_files,
               kind: "note",
               idempotency_key: "auto-promote-#{System.unique_integer([:positive])}",
               source_ref: "notes://launch.md",
               body: "notes content must not become durable memory"
             })

    IO.puts("local-knowledge-no-auto-memory-promotion-001 status=pass promotion=blocked")

    AssertBinding.check!("local-knowledge-no-auto-memory-promotion-001", [
      :new_entry_unreviewed,
      :notes_namespace_not_writable
    ])
  end

  test "local-knowledge-memory-review-user-controlled-001: keep runs through the permissioned action" do
    # The review action carries the existing :memory_write authority — no new class.
    assert ReviewMemoryEntry.capability().permission == :memory_write

    assert {:ok, entry} = append("alice", "Keep this reviewed preference.")
    assert entry.review_status == :unreviewed

    assert {:ok, response} =
             ReviewMemoryEntry.run(
               %{path: entry.path, status: "kept"},
               memory_context("alice")
             )

    assert response.status == :completed
    assert response.entry.review_status == :kept

    IO.puts(
      "local-knowledge-memory-review-user-controlled-001 status=pass review=user_controlled"
    )

    AssertBinding.check!("local-knowledge-memory-review-user-controlled-001", [
      :review_requires_memory_write,
      :review_marks_kept,
      :human_controlled_transition
    ])
  end

  test "local-knowledge-review-panel-no-authority-001: the workspace:memory panel adds no authority" do
    panel_source =
      "apps/allbert_assist_web/lib/allbert_assist_web/workspace/components/operator_panels.ex"
      |> read!()

    panel = memory_panel_slice(panel_source)

    # Keep/reject/delete dispatch the existing registered actions through the Runner.
    assert panel =~ ~s|Runner.run("review_memory_entry"|
    assert panel =~ ~s|Runner.run("delete_memory_entry"|

    # Delete is routed through the confirmation-gated archive (create+approve).
    assert panel =~ "approve_confirmation"
    assert DeleteMemoryEntry.capability().confirmation == :required

    # The panel never mutates memory directly — no bypass of the action boundary.
    refute panel =~ "Memory.review_entry("
    refute panel =~ "Memory.delete_entry("
    refute panel =~ "Memory.archive"

    IO.puts("local-knowledge-review-panel-no-authority-001 status=pass panel=runner_dispatch")

    AssertBinding.check!("local-knowledge-review-panel-no-authority-001", [
      :panel_dispatches_registered_actions,
      :delete_confirmation_gated,
      :no_direct_memory_mutation
    ])
  end

  test "local-knowledge-memory-reject-flagged-001: reject maps to the :flagged status" do
    assert {:ok, entry} = append("alice", "Reject this stray note.")

    assert {:ok, response} =
             ReviewMemoryEntry.run(
               %{path: entry.path, status: "flagged"},
               memory_context("alice")
             )

    assert response.status == :completed
    assert response.entry.review_status == :flagged
    refute response.entry.review_status == :kept

    IO.puts("local-knowledge-memory-reject-flagged-001 status=pass reject=flagged")

    AssertBinding.check!("local-knowledge-memory-reject-flagged-001", [
      :reject_maps_to_flagged,
      :flagged_not_kept
    ])
  end

  test "local-knowledge-memory-status-001: status reports exact per-status counts" do
    assert {:ok, _unreviewed} = append("alice", "Unreviewed candidate.")
    assert {:ok, kept} = append("alice", "Kept candidate.")
    assert {:ok, flagged} = append("alice", "Flagged candidate.")

    {:ok, _} = review(kept, :kept)
    {:ok, _} = review(flagged, :flagged)

    counts = Memory.review_status_counts()

    # Exact counts by review_status (not a bounded list sample), with a total.
    assert counts.unreviewed == 1
    assert counts.kept == 1
    assert counts.flagged == 1
    assert counts.prune_nominated == 0
    assert counts.total == 3

    IO.puts("local-knowledge-memory-status-001 status=pass counts=exact")

    AssertBinding.check!("local-knowledge-memory-status-001", [
      :status_counts_exact,
      :counts_by_review_status,
      :total_reported
    ])
  end

  test "local-knowledge-recall-reviewed-memory-001: recall retrieves only :kept memory" do
    {:ok, kept} = append("alice", "Kept-only reviewed reports may be recalled.")
    {:ok, kept} = review(kept, :kept)
    {:ok, unreviewed} = append("alice", "Unreviewed reports must be excluded from recall.")
    {:ok, flagged} = append("alice", "Flagged reports must be excluded from recall.")
    {:ok, flagged} = review(flagged, :flagged)

    assert {:ok, result} =
             ActiveMemory.retrieve("reports",
               user_id: "alice",
               active_app: nil,
               now: @now
             )

    retrieved = Enum.map(result.chunks, & &1.entry_path)

    assert kept.path in retrieved
    refute unreviewed.path in retrieved
    refute flagged.path in retrieved

    IO.puts("local-knowledge-recall-reviewed-memory-001 status=pass recall=kept_only")

    AssertBinding.check!("local-knowledge-recall-reviewed-memory-001", [
      :recall_kept_only,
      :unreviewed_excluded,
      :flagged_excluded
    ])
  end

  test "local-knowledge-v066-handoff-current-001: the v0.66 no-docs validation handoff is current" do
    flow = read!("docs/plans/archives/v0.65-request-flow.md")
    roadmap = read!("docs/plans/roadmap.md")

    assert flow =~ "local-knowledge-v066-handoff-current-001"
    assert flow =~ "v0.66 handoff is current"

    assert roadmap =~ "v0.66 Product RC & No-Docs Validation"
    assert roadmap =~ "local files/notes/memory"

    IO.puts("local-knowledge-v066-handoff-current-001 status=pass handoff=current")

    AssertBinding.check!("local-knowledge-v066-handoff-current-001", [
      :v066_handoff_present,
      :no_docs_validation_named,
      :local_knowledge_handoff_current
    ])
  end

  test "every :v065 row binds its assert atoms in its owning test" do
    sources = Map.new(@owner_files, fn {mod, path} -> {mod, read!(path)} end)

    for row <- EvalInventory.rows_for_milestone(:v065) do
      source = Map.fetch!(sources, row.test_module)

      assert source =~ ~s|check!("#{row.id}"|,
             "row #{row.id} has no AssertBinding.check!/2 binding in #{row.test_module}"
    end

    IO.puts("v065-assert-atom-binding status=pass rows=13 unbound=0")
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp connect_notes!(notes_root) do
    assert {:ok, %{status: :completed}} = SetNotesRoot.run(%{path: notes_root}, action_context())
    :ok
  end

  defp action_context do
    %{
      active_app: :notes_files,
      request: %{
        active_app: :notes_files,
        operator_id: "local",
        channel: :test,
        input_signal_id: "sig"
      }
    }
  end

  defp memory_context(user_id) do
    %{
      user_id: user_id,
      operator_id: user_id,
      actor: user_id,
      channel: :test,
      request: %{operator_id: user_id, user_id: user_id, channel: :test, input_signal_id: "sig"}
    }
  end

  defp append(actor, body) do
    Memory.append(%{
      category: :notes,
      body: body,
      summary: body,
      actor: actor,
      agent: "security-eval",
      channel: :test,
      source_signal_id: "security-eval"
    })
  end

  defp review(entry, status) do
    Memory.review_entry(
      entry.path,
      %{status: status, reviewed_at: @now, reviewed_by: entry.actor},
      user_id: entry.actor
    )
  end

  defp memory_panel_slice(source) do
    case String.split(source, "defmodule AllbertAssistWeb.Workspace.Components.MemoryPanel",
           parts: 2
         ) do
      [_before, panel] -> panel
      [only] -> only
    end
  end

  defp read!(relative) do
    @repo_root |> Path.join(relative) |> File.read!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
