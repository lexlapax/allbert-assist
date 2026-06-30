defmodule AllbertAssist.Security.V060SweepEvalTest do
  @moduledoc """
  v0.60 design-release sweep.

  These evals are file-backed checks for the design artifacts, ADR acceptance, and
  downstream handoff contract. The walking-skeleton runtime rows are registered in
  the same inventory but are asserted by the web skeleton test.
  """
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.SecurityFixtures.EvalInventory

  @eval_groups [
    design_artifacts:
      ~w(product-experience-spec-present-001 information-architecture-spec-present-001 first-model-path-design-present-001 onboarding-flow-design-present-001 persona-model-design-present-001 entry-point-cli-ux-design-present-001 design-system-gap-analysis-present-001),
    adr_acceptance: ~w(adr-0077-accepted-001 adr-0078-first-model-path-accepted-001),
    walking_skeleton:
      ~w(walking-skeleton-routes-resolve-001 walking-skeleton-nav-shell-001 walking-skeleton-a11y-smoke-001 no-new-authority-design-only-001),
    handoff: ~w(rc-design-handoff-no-drift-001)
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()
  @sweep_owned_ids @eval_groups
                   |> Keyword.take([:design_artifacts, :adr_acceptance, :handoff])
                   |> Keyword.values()
                   |> List.flatten()
  @web_owned_ids Keyword.fetch!(@eval_groups, :walking_skeleton)
  @repo_root Path.expand("../../../../", __DIR__)

  test "v0.60 eval inventory rows are complete and routed to their owning tests" do
    rows = EvalInventory.rows_for_milestone(:v060)
    row_ids = Enum.map(rows, & &1.id)
    rows_by_id = Map.new(rows, &{&1.id, &1})

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.milestone == :v060))

    for id <- @sweep_owned_ids do
      assert rows_by_id[id].test_module == "AllbertAssist.Security.V060SweepEvalTest"
    end

    for id <- @web_owned_ids do
      assert rows_by_id[id].test_module == "AllbertAssistWeb.Skeleton.WalkingSkeletonTest"
    end
  end

  test "v0.60 sweep rows encode concrete pass criteria" do
    rows = EvalInventory.rows_for_milestone(:v060)

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert)
      assert length(row.assert) >= 3
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
    end
  end

  test "design artifacts are present and carry their v0.60 handoff contracts" do
    product = read!("docs/design/product-experience-spec.md")

    assert_contains!(product, [
      "Install",
      "First-run",
      "Onboard",
      "First-value",
      "Daily-use",
      "first useful chat",
      "v0.61",
      "v0.62",
      "v0.63",
      "v0.64"
    ])

    IO.puts(
      "product-experience-spec-present-001 status=pass stages=install,first-run,onboard,first-value,daily-use first_value=first useful chat owners=v0.61,v0.62,v0.63,v0.64"
    )

    ia = read!("docs/design/information-architecture.md")

    assert_contains!(ia, [
      "## Sitemap",
      "## Screen Inventory",
      "## Navigation Model",
      "## Workspace Composition",
      "## Preview Route Manifest"
    ])

    IO.puts(
      "information-architecture-spec-present-001 status=pass sitemap=true screen_inventory=true navigation_model=true composition_rules=true preview_route_manifest=true"
    )

    first_model = read!("docs/design/first-model-path.md")

    assert_contains!(first_model, [
      "QuickStart default: assisted-local",
      "BYOK",
      "Rejected: managed-hosted default",
      "first useful chat",
      "## v0.62 Packaging Implications"
    ])

    IO.puts(
      "first-model-path-design-present-001 status=pass quickstart=assisted-local byok=fallback managed_hosted=rejected packaging=v0.62"
    )

    onboarding = read!("docs/design/onboarding-flow.md")

    assert_contains!(onboarding, [
      "QuickStart",
      "Advanced",
      "first useful chat",
      "Handoff To v0.63",
      "v0.60 M4 design artifact and v0.63 design input"
    ])

    IO.puts(
      "onboarding-flow-design-present-001 status=pass two_track=true quickstart=true advanced=true consumer=v0.63"
    )

    persona = read!("docs/design/persona-model.md")

    assert_contains!(persona, [
      "`researcher`",
      "`developer`",
      "`writer`",
      "`ops`",
      "`general`",
      "review diff",
      "no capability",
      "Handoff To v0.63"
    ])

    IO.puts(
      "persona-model-design-present-001 status=pass personas=researcher,developer,writer,ops,general review_confirm=true consumer=v0.63"
    )

    entry_point = read!("docs/design/entry-point-cli-ux.md")

    assert_contains!(entry_point, [
      "## Command Taxonomy",
      "## First-Run Detection",
      "## Wizard Launch Sequence",
      "wizard launch",
      "Handoff To v0.62"
    ])

    IO.puts(
      "entry-point-cli-ux-design-present-001 status=pass command_taxonomy=true first_run_detection=true wizard_launch=true consumer=v0.62"
    )

    design_system = read!("docs/design/design-system-gap-analysis.md")

    assert_contains!(design_system, [
      "## Token Gaps",
      "## Component-Variant Gaps",
      "## Pattern Gaps",
      "ADR 0074 v0.61 input",
      "## v0.61 Work Packages"
    ])

    IO.puts(
      "design-system-gap-analysis-present-001 status=pass token_gaps=true component_variant_gaps=true pattern_gaps=true consumer=v0.61"
    )
  end

  test "ADR 0077 and ADR 0078 are accepted v0.60 decisions" do
    adr_0077 = read!("docs/adr/0077-product-experience-design-and-information-architecture.md")

    assert_contains!(adr_0077, [
      "Status: Accepted (v0.60)",
      "Information Architecture",
      "navigation",
      "screen/workspace composition",
      "ADR 0074"
    ])

    IO.puts("adr-0077-accepted-001 status=pass decision=accepted_v060")

    adr_0078 = read!("docs/adr/0078-first-model-path.md")

    assert_contains!(adr_0078, [
      "Status: Accepted (v0.60)",
      "assisted-local",
      "managed-hosted default is rejected",
      "BYOK",
      "first useful chat"
    ])

    IO.puts(
      "adr-0078-first-model-path-accepted-001 status=pass decision=accepted_v060 assisted_local=true byok_fallback=true managed_hosted_rejected=true"
    )
  end

  @tag :rc_design_handoff
  test "v0.60 handoff names downstream consumers without build-scope drift" do
    plan = read!("docs/plans/v0.60-plan.md")
    request_flow = read!("docs/plans/v0.60-request-flow.md")

    assert_contains!(plan, [
      "No presentation, packaging, onboarding, or RC implementation.",
      "v0.60 boundary (design + scaffolding only; presentation",
      "v0.62, onboarding/personas",
      "product RC",
      "v0.64"
    ])

    assert_contains!(request_flow, [
      "rc-design-handoff-no-drift-001 consumer=v0.61 output=information-architecture+design-system-gap-analysis+first-model-path status=no-drift",
      "rc-design-handoff-no-drift-001 consumer=v0.62 output=entry-point-cli-ux+first-model-path-packaging status=no-drift",
      "rc-design-handoff-no-drift-001 consumer=v0.63 output=onboarding-flow+persona-model+first-model-path status=no-drift",
      "rc-design-handoff-no-drift-001 no-drift consumers=v0.61,v0.62,v0.63"
    ])

    IO.puts(
      "rc-design-handoff-no-drift-001 consumer=v0.61 output=information-architecture+design-system-gap-analysis+first-model-path status=no-drift"
    )

    IO.puts(
      "rc-design-handoff-no-drift-001 consumer=v0.62 output=entry-point-cli-ux+first-model-path-packaging status=no-drift"
    )

    IO.puts(
      "rc-design-handoff-no-drift-001 consumer=v0.63 output=onboarding-flow+persona-model+first-model-path status=no-drift"
    )

    IO.puts("rc-design-handoff-no-drift-001 no-drift consumers=v0.61,v0.62,v0.63")
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
