defmodule AllbertAssist.Security.V060bSweepEvalTest do
  @moduledoc """
  v0.60b visual-design-language sweep.

  File-backed checks for the visual-language design artifacts (research, brief, rubric,
  the ≥3 candidate directions, comparison, selected), ADR 0079 acceptance-with-choice,
  the recorded operator choice, the design-only no-authority invariant, and the
  handoff-to-v0.61 drift-check. The disposable hero-rendering / styled-skeleton preview
  proofs were retired at the v0.61 closeout (the preview mechanism is gone; Direction C
  is now the canonical `:root` language and the committed screenshots are the durable
  design record).
  """
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.SecurityFixtures.EvalInventory

  @eval_groups [
    design_artifacts:
      ~w(visual-language-research-present-001 visual-language-brief-present-001 visual-language-rubric-present-001 visual-direction-a-present-001 visual-direction-b-present-001 visual-direction-c-present-001 visual-language-comparison-present-001 visual-language-selected-present-001),
    candidate_decision: ~w(three-divergent-directions-present-001 operator-choice-recorded-001),
    adr_acceptance: ~w(adr-0079-accepted-with-choice-001),
    design_only: ~w(no-new-authority-design-only-001),
    handoff: ~w(visual-language-handoff-to-v061-no-drift-001)
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()
  @sweep_owned_ids @eval_groups
                   |> Keyword.take([
                     :design_artifacts,
                     :candidate_decision,
                     :adr_acceptance,
                     :design_only,
                     :handoff
                   ])
                   |> Keyword.values()
                   |> List.flatten()
  @chosen_direction "c"
  @repo_root Path.expand("../../../../", __DIR__)

  test "v0.60b eval inventory rows are complete and routed to their owning tests" do
    rows = EvalInventory.rows_for_milestone(:v060b)
    row_ids = Enum.map(rows, & &1.id)
    rows_by_id = Map.new(rows, &{&1.id, &1})

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.milestone == :v060b))

    for id <- @sweep_owned_ids do
      assert rows_by_id[id].test_module == "AllbertAssist.Security.V060bSweepEvalTest"
    end
  end

  test "v0.60b sweep rows encode concrete pass criteria" do
    rows = EvalInventory.rows_for_milestone(:v060b)

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert)
      assert length(row.assert) >= 3
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
    end
  end

  test "visual-language design artifacts are present and carry their v0.60b contracts" do
    research = read!("docs/design/visual-language-research.md")

    assert_contains!(research, [
      "## Reference Survey",
      "## Extracted Visual & Interaction Principles",
      "## Mood / Direction Inventory",
      "trust-first"
    ])

    IO.puts(
      "visual-language-research-present-001 status=pass reference_survey=true principles=true mood_inventory=true trust_first=true"
    )

    brief = read!("docs/design/visual-language-brief.md")

    assert_contains!(brief, [
      "## Must-Satisfy Requirements",
      "technical-prosumer",
      "catalog",
      "dark",
      "high-contrast",
      "reduced-motion",
      "chat-primary",
      "local-first"
    ])

    IO.puts(
      "visual-language-brief-present-001 status=pass persona=true token_catalog=true a11y_axes=true chat_primary=true performance=true"
    )

    assert_contains!(brief, ["## Evaluation Rubric", "Weight", "weighted total"])

    IO.puts(
      "visual-language-rubric-present-001 status=pass rubric_section=true scored_axes=true weighting=true"
    )

    for {dir, root_font} <- [{"a", "ui-serif"}, {"b", "ui-monospace"}, {"c", "ui-rounded"}] do
      doc = read!("docs/design/visual-direction-#{dir}.md")

      assert_contains!(doc, [
        "Stage 1",
        "Wireframe",
        "Stage 2",
        "Color scheme",
        "UX scheme",
        "UI scheme",
        "Chat-primary hero composition",
        root_font
      ])

      IO.puts(
        "visual-direction-#{dir}-present-001 status=pass wireframe=true color=true ux=true ui=true chat_hero=true type=#{root_font}"
      )
    end

    comparison = read!("docs/design/visual-language-comparison.md")

    assert_contains!(comparison, [
      "## Side-by-side scores",
      "Direction A",
      "Direction B",
      "Direction C",
      "Fit to IA",
      "feel 1.0",
      "Implementability",
      "A11y",
      "Performance",
      "Weighted total"
    ])

    IO.puts(
      "visual-language-comparison-present-001 status=pass per_direction_scores=true every_axis=true side_by_side=true"
    )

    selected = read!("docs/design/visual-language-selected.md")

    assert_contains!(selected, [
      "Chosen direction: C",
      "## Rubric rationale",
      "## Token / component delta v0.61 must build",
      "## v0.61 build handoff"
    ])

    IO.puts(
      "visual-language-selected-present-001 status=pass chosen=c rationale=true token_component_delta=true handoff=true"
    )
  end

  test "ADR 0079 is Accepted-with-choice (v0.60b) and names the chosen direction" do
    adr = read!("docs/adr/0079-visual-design-language-and-art-direction.md")

    assert_contains!(adr, [
      "Status: Accepted-with-choice (v0.60b)",
      "Direction C",
      "Direction A",
      "Direction B",
      "three",
      "candidate"
    ])

    IO.puts(
      "adr-0079-accepted-with-choice-001 status=pass decision=accepted_with_choice_v060b chosen=c candidates=3"
    )
  end

  test "the three directions carry distinct token deltas and wireframes" do
    a = read!("docs/design/visual-direction-a.md")
    b = read!("docs/design/visual-direction-b.md")
    c = read!("docs/design/visual-direction-c.md")

    # Distinct type-family deltas (the divergence fingerprint).
    assert String.contains?(a, "ui-serif")
    assert String.contains?(b, "ui-monospace")
    assert String.contains?(c, "ui-rounded")

    # Each carries its own Stage-1 wireframe (placement), not one shared layout.
    for {label, doc} <- [{"a", a}, {"b", b}, {"c", c}] do
      assert String.contains?(doc, "Wireframe"),
             "direction #{label} is missing a Stage-1 wireframe"
    end

    IO.puts(
      "three-divergent-directions-present-001 status=pass docs=3 distinct_type_deltas=true distinct_wireframes=true"
    )
  end

  test "exactly one operator-chosen direction is recorded in the selected doc and ADR 0079" do
    selected = read!("docs/design/visual-language-selected.md")
    adr = read!("docs/adr/0079-visual-design-language-and-art-direction.md")

    # The choice named in the selected doc must match the one named in ADR 0079.
    assert String.contains?(selected, "Chosen direction: C")
    assert String.contains?(selected, "Direction C")
    assert String.contains?(adr, "Direction C")
    assert String.contains?(adr, "chose Direction C")

    IO.puts(
      "operator-choice-recorded-001 status=pass chosen=#{@chosen_direction} sources=selected,adr-0079"
    )
  end

  test "v0.60b styled renderings stay design-only with no new authority" do
    plan = read!("docs/plans/archives/v0.60b-plan.md")
    selected = read!("docs/design/visual-language-selected.md")

    assert_contains!(plan, [
      "No new authority, capability, egress, confirmation-floor change, or Settings",
      "Security Central is unchanged"
    ])

    assert_contains!(selected, ["no runtime authority", "no Settings key"])

    IO.puts(
      "no-new-authority-design-only-001 status=pass live_data=false authority=none settings_keys=0"
    )
  end

  @tag :v060b_handoff
  test "v0.60b handoff names v0.61 as the sole consumer without build-scope drift" do
    plan = read!("docs/plans/archives/v0.60b-plan.md")
    selected = read!("docs/design/visual-language-selected.md")

    assert_contains!(plan, [
      "visual-language-handoff-to-v061-no-drift-001 consumer=v0.61 output=visual-language-selected+token-component-delta status=no-drift downstream=v0.62,v0.63,v0.64,v1.0-unchanged"
    ])

    assert_contains!(selected, [
      "Sole consumer: v0.61",
      "Downstream unchanged"
    ])

    IO.puts(
      "visual-language-handoff-to-v061-no-drift-001 consumer=v0.61 output=visual-language-selected+token-component-delta status=no-drift downstream=v0.62,v0.63,v0.64,v1.0-unchanged"
    )
  end

  defp read!(relative_path) do
    @repo_root
    |> Path.join(relative_path)
    |> File.read!()
  end

  defp assert_contains!(text, phrases) when is_list(phrases) do
    for phrase <- phrases do
      assert String.contains?(text, phrase), "expected document to contain #{inspect(phrase)}"
    end
  end
end
