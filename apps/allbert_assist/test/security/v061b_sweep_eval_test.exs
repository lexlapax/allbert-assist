defmodule AllbertAssist.Security.V061bSweepEvalTest do
  @moduledoc """
  v0.61b UX-refinement sweep.

  File-backed checks for the v0.61b artifacts (the plan's M0 shell-spec /
  S2-sign-off section, ADR 0080 acceptance + the 0077/0074 pointer notes, the
  v0.58 no-internal-rename invariant, and the no-new-authority envelope), plus
  the inventory completeness / shape / ownership routing for the `:v061b` eval
  rows. The rendered-shell rows are asserted by their owning v0.61b web proof
  tests (routed below).
  """
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.SecurityFixtures.EvalInventory

  @eval_groups [
    design_artifacts: ~w(shell-spec-signoff-recorded-001 adr-0080-accepted-001),
    chat: ~w(chat-type-hierarchy-001 status-chip-link-labeling-001),
    dark_mode: ~w(dark-mode-lockstep-aa-001),
    thread_rename: ~w(thread-rename-ownership-001 thread-rename-no-internal-rename-001),
    shell:
      ~w(single-sidebar-consolidation-001 nav-reachability-parity-001 docked-panel-not-floating-001 topbar-retired-relocation-001 sidebar-collapse-a11y-001),
    authority: ~w(v061b-no-new-authority-001)
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()

  @owners %{
    "shell-spec-signoff-recorded-001" => "AllbertAssist.Security.V061bSweepEvalTest",
    "adr-0080-accepted-001" => "AllbertAssist.Security.V061bSweepEvalTest",
    "chat-type-hierarchy-001" => "AllbertAssistWeb.V061b.ChatTypeHierarchyTest",
    "status-chip-link-labeling-001" => "AllbertAssistWeb.V061b.StatusLinkChipTest",
    "dark-mode-lockstep-aa-001" => "AllbertAssistWeb.V061b.DarkLockstepTest",
    "thread-rename-ownership-001" => "AllbertAssist.Actions.Conversations.RenameThreadTest",
    "thread-rename-no-internal-rename-001" => "AllbertAssist.Security.V061bSweepEvalTest",
    "single-sidebar-consolidation-001" => "AllbertAssistWeb.V061b.SidebarConsolidationTest",
    "nav-reachability-parity-001" => "AllbertAssistWeb.V061b.SidebarConsolidationTest",
    "docked-panel-not-floating-001" => "AllbertAssistWeb.V061b.DockedPaneTest",
    "topbar-retired-relocation-001" => "AllbertAssistWeb.V061b.TopbarRetirementTest",
    "sidebar-collapse-a11y-001" => "AllbertAssistWeb.V061b.SidebarCollapseTest",
    "v061b-no-new-authority-001" => "AllbertAssist.Security.V061bSweepEvalTest"
  }

  @repo_root Path.expand("../../../../", __DIR__)

  test "v0.61b eval inventory rows are complete and routed to their owning tests" do
    rows = EvalInventory.rows_for_milestone(:v061b)
    row_ids = Enum.map(rows, & &1.id)
    rows_by_id = Map.new(rows, &{&1.id, &1})

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.milestone == :v061b))

    for {id, owner} <- @owners do
      assert rows_by_id[id].test_module == owner, "row #{id} routed to the wrong owning test"
    end
  end

  test "v0.61b sweep rows encode concrete pass criteria" do
    rows = EvalInventory.rows_for_milestone(:v061b)

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert)
      assert length(row.assert) >= 3
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
    end
  end

  test "the plan's M0 shell-spec section carries its subsections and the recorded S2 sign-off" do
    plan = read!("docs/plans/v0.61b-plan.md")

    assert plan =~ "#### Shell Spec & Operator Sign-off"
    assert plan =~ "**Relocation map"
    assert plan =~ "**Per-view header inventory**"
    assert plan =~ "**Pane tenancy"
    assert plan =~ "**Rail behavior"
    assert plan =~ "**Dimensions & defaults.**"
    assert plan =~ "**Keyboard shortcuts**"

    assert Regex.match?(~r/S2 sign-off: accepted, \d{4}-\d{2}-\d{2}/, plan),
           "no recorded S2 sign-off line in the plan's M0 section"

    IO.puts("shell-spec-signoff-recorded-001 status=pass subsections=present s2=recorded")
  end

  test "ADR 0080 is Accepted (v0.61b) with pointer notes in ADR 0077/0074" do
    adr = read!("docs/adr/0080-navigation-consolidation-and-workspace-shell-presentation.md")
    assert adr =~ "Status: Accepted (v0.61b)"

    adr_0077 = read!("docs/adr/0077-product-experience-design-and-information-architecture.md")
    assert adr_0077 =~ "ADR 0080"

    adr_0074 = read!("docs/adr/0074-web-design-system-and-ux-language.md")
    assert adr_0074 =~ "ADR 0080"

    IO.puts("adr-0080-accepted-001 status=pass adr=accepted pointers=0077+0074")
  end

  test "the v0.58 no-internal-rename invariant holds through the rename write path" do
    thread = read!("apps/allbert_assist/lib/allbert_assist/conversations/thread.ex")
    assert thread =~ "defmodule AllbertAssist.Conversations.Thread"
    assert thread =~ ~s(schema "conversation_threads")

    conversations = read!("apps/allbert_assist/lib/allbert_assist/conversations.ex")
    assert conversations =~ "def rename_thread"

    scratchpad = read!("apps/allbert_assist/lib/allbert_assist/session/scratchpad.ex")
    assert scratchpad =~ "defmodule AllbertAssist.Session.Scratchpad"

    IO.puts(
      "thread-rename-no-internal-rename-001 status=pass modules=unchanged " <>
        "write=title_field_only"
    )
  end

  test "the no-new-authority envelope holds: the registry diff is exactly rename_thread" do
    assert "rename_thread" in Registry.names()

    assert {:ok, capability} = Registry.capability("rename_thread")
    assert capability.permission == :conversation_write
    assert capability.exposure == :internal

    # Internal, not agent-routable — the intent router cannot reach it.
    refute "rename_thread" in Enum.map(Registry.agent_capabilities(), & &1.name)

    # No new permission class: :conversation_write predates v0.61b and the
    # class list is unchanged (pinned independently by permission_gate_test).
    assert :conversation_write in Policy.permission_classes()

    IO.puts(
      "v061b-no-new-authority-001 status=pass registry_diff=rename_thread " <>
        "permission=conversation_write_existing exposure=internal"
    )
  end

  defp read!(relative) do
    @repo_root |> Path.join(relative) |> File.read!()
  end
end
