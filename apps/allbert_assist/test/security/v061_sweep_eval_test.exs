defmodule AllbertAssist.Security.V061SweepEvalTest do
  @moduledoc """
  v0.61 presentation-overhaul sweep.

  File-backed checks for the v0.61 design artifacts (the layout exploration/selection
  docs and the committed screenshot design record), plus the inventory completeness /
  shape / ownership routing for the `:v061` eval rows. The rendering, token, nav,
  brand, motion, dark-mode, and hierarchy rows are registered in the same inventory
  but asserted by their owning web proof tests (routed below).
  """
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.SecurityFixtures.EvalInventory

  @surfaces ~w(launch onboarding workspace objectives jobs models channels settings trust)

  @eval_groups [
    layout_rendering: ~w(layout-systems-rendered-001),
    visual_language: ~w(visual-language-direction-c-tokens-first-class-001),
    navigation: ~w(ia-navigation-model-implemented-001 route-contract-no-sprawl-001),
    brand: ~w(brand-asset-no-stock-logo-001 brand-identity-selected-recorded-001),
    motion: ~w(motion-token-driven-001 motion-respects-reduced-motion-001),
    dark_mode: ~w(dark-mode-os-resolution-001),
    design_tokens: ~w(design-tokens-global-conformance-001),
    design_artifacts:
      ~w(layout-systems-explored-present-001 operator-layout-choice-recorded-001 layout-screenshot-design-record-001)
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()
  @sweep_owned_ids Keyword.fetch!(@eval_groups, :design_artifacts)

  @owners %{
    "layout-systems-rendered-001" => "AllbertAssistWeb.Skeleton.LayoutSystemProofTest",
    "visual-language-direction-c-tokens-first-class-001" =>
      "AllbertAssistWeb.Workspace.DirectionCTokensTest",
    "ia-navigation-model-implemented-001" => "AllbertAssistWeb.OperatorShellNavTest",
    "route-contract-no-sprawl-001" => "AllbertAssistWeb.OperatorShellNavTest",
    "brand-asset-no-stock-logo-001" => "AllbertAssistWeb.BrandLandingTest",
    "brand-identity-selected-recorded-001" => "AllbertAssistWeb.BrandLandingTest",
    "motion-token-driven-001" => "AllbertAssistWeb.Workspace.MotionLayerTest",
    "motion-respects-reduced-motion-001" => "AllbertAssistWeb.Workspace.MotionLayerTest",
    "dark-mode-os-resolution-001" => "AllbertAssistWeb.DarkModeResolutionTest",
    "design-tokens-global-conformance-001" => "AllbertAssistWeb.Workspace.VisualHierarchyTest",
    "layout-systems-explored-present-001" => "AllbertAssist.Security.V061SweepEvalTest",
    "operator-layout-choice-recorded-001" => "AllbertAssist.Security.V061SweepEvalTest",
    "layout-screenshot-design-record-001" => "AllbertAssist.Security.V061SweepEvalTest"
  }

  @repo_root Path.expand("../../../../", __DIR__)

  test "v0.61 eval inventory rows are complete and routed to their owning tests" do
    rows = EvalInventory.rows_for_milestone(:v061)
    row_ids = Enum.map(rows, & &1.id)
    rows_by_id = Map.new(rows, &{&1.id, &1})

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.milestone == :v061))

    for {id, owner} <- @owners do
      assert rows_by_id[id].test_module == owner, "row #{id} routed to the wrong owning test"
    end
  end

  test "v0.61 sweep rows encode concrete pass criteria" do
    rows = EvalInventory.rows_for_milestone(:v061)

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert)
      assert length(row.assert) >= 3
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
    end
  end

  test "layout-systems-explored.md specifies >=3 divergent systems across all nine surfaces" do
    doc = read!("docs/design/layout-systems-explored.md")

    systems =
      Regex.scan(~r/System\s+([A-D])\b/, doc) |> Enum.map(&List.last/1) |> Enum.uniq()

    assert length(systems) >= 3, "expected >=3 layout systems, saw #{inspect(systems)}"

    for surface <- @surfaces do
      assert doc =~ surface, "explored doc missing surface: #{surface}"
    end

    IO.puts(
      "layout-systems-explored-present-001 status=pass systems=#{length(systems)} surfaces=9"
    )
  end

  test "layout-systems-selected.md records exactly one CHOSEN_LAYOUT with rationale + spec" do
    doc = read!("docs/design/layout-systems-selected.md")

    chosen = Regex.scan(~r/CHOSEN_LAYOUT:\s*([a-d])/i, doc) |> Enum.map(&List.last/1)
    assert chosen == ["d"], "expected exactly one CHOSEN_LAYOUT (d), saw #{inspect(chosen)}"

    assert doc =~ ~r/rubric/i
    assert doc =~ ~r/per-surface/i

    IO.puts("operator-layout-choice-recorded-001 status=pass chosen=d")
  end

  test "the committed layout screenshot design record is complete for all nine surfaces" do
    dir = Path.join(@repo_root, "docs/design/layout-systems")
    assert File.dir?(dir)

    for surface <- @surfaces do
      assert File.exists?(Path.join(dir, "#{surface}-side-by-side.png")),
             "missing side-by-side screenshot for #{surface}"

      assert File.exists?(Path.join(dir, "selected-layout-d-#{surface}.png")),
             "missing selected-layout screenshot for #{surface}"

      assert Path.wildcard(Path.join(dir, "layout-*-#{surface}.png")) != [],
             "missing per-system screenshots for #{surface}"
    end

    IO.puts("layout-screenshot-design-record-001 status=pass surfaces=9 record=committed")
  end

  # Not owned here; guards the ownership table against silent drift.
  test "sweep-owned ids are exactly the design-artifact rows" do
    assert MapSet.new(@sweep_owned_ids) ==
             MapSet.new(
               for {id, owner} <- @owners,
                   owner == "AllbertAssist.Security.V061SweepEvalTest",
                   do: id
             )
  end

  defp read!(rel), do: File.read!(Path.join(@repo_root, rel))
end
