defmodule AllbertAssist.Security.V058SurfaceConsistencyEvalTest do
  @moduledoc """
  v0.58 surface consistency, settings enforcement, web design-system, operator-panel,
  surface-policy, and helper-consolidation release eval inventory checks.
  """
  use AllbertAssist.SecurityEvalCase, async: true

  alias AllbertAssist.SecurityFixtures.EvalInventory

  @eval_groups [
    surface_consistency: ~w(
      surface-renderer-unified-parity-001
      surface-event-audit-parity-001
      web-reads-action-backed-001
      web-identity-resolved-001
      surface-invocation-shared-001
    ),
    settings_enforcement: ~w(
      settings-no-bypass-001
    ),
    web_design_system: ~w(
      design-tokens-global-001
      component-variant-registry-001
      pattern-library-a11y-001
      all-pages-catalog-shell-001
      chat-primary-default-001
      ephemeral-renders-as-modal-dialog-001
      conversations-relabel-ui-only-001
      workspace-shell-validates-against-catalog-001
      fragment-emission-hmac-validated-001
      launcher-selection-view-only-001
      mobile-single-column-and-reduced-motion-001
    ),
    operator_panel_surface_policy: ~w(
      intents-panel-v056-dto-parity-001
      intents-panel-gated-promotion-001
      models-panel-v056-dto-redaction-001
      surface-policy-raw-report-affordance-001
      surface-policy-settings-central-001
      surface-policy-no-authority-grant-001
    ),
    redundancy: ~w(
      redundancy-consolidation-no-regression-001
    )
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()

  test "v0.58 eval inventory rows are complete and grouped by implemented surface" do
    rows = EvalInventory.rows_for_milestone(:v058)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.milestone == :v058))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))

    assert_eval_group!(:surface_consistency, :surface_consistency)
    assert_eval_group!(:settings_enforcement, :settings_enforcement)
    assert_eval_group!(:web_design_system, :web_design_system)
    assert_eval_group!(:operator_panel_surface_policy, :surface_policy)
    assert_eval_group!(:redundancy, :redundancy_consolidation)
  end

  test "v0.58 release eval rows encode both positive conformance and denied bypass cases" do
    rows = EvalInventory.rows_for_milestone(:v058)

    assert Enum.any?(rows, &(&1.expected == :allowed))
    assert Enum.any?(rows, &(&1.expected == :denied))

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert)
      assert row.assert != []
      assert row.scenario =~ ~r/\w/
    end
  end

  defp assert_eval_group!(group, surface) do
    ids = Keyword.fetch!(@eval_groups, group)
    milestone_rows = EvalInventory.rows_for_milestone(:v058)
    rows = Enum.map(ids, &find_eval_row!(milestone_rows, &1))

    assert Enum.map(rows, & &1.id) == ids
    assert Enum.all?(rows, &(&1.surface == surface))
  end

  defp find_eval_row!(rows, id) do
    Enum.find(rows, &(&1.id == id)) || flunk("missing v0.58 eval row #{id}")
  end
end
