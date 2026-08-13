defmodule AllbertAssist.Security.V121SweepEvalTest do
  alias AllbertAssist.DevGates.GateOwners

  @moduledoc """
  Exact routing sweep for the v1.2.1 release-bound security rows.

  The production-bound assertions stay in their existing focused owner suites.
  This sweep prevents the inventory, owner routing, and `AssertBinding` calls
  from drifting while `release.v121` executes those owner suites separately.
  """

  use AllbertAssist.SecurityEvalCase, async: false, lane: :security_eval_serial

  alias AllbertAssist.SecurityFixtures.EvalInventory

  @repo_root Path.expand("../../../../", __DIR__)

  @ids ~w[
    v121-license-final-artifact-001
    v121-license-known-seam-001
    v121-license-determinism-001
    v121-license-castore-001
    v121-license-viewer-001
    v121-tui-legacy-attach-001
    v121-system-integrity-key-001
    v121-tui-no-daemon-001
    v121-tui-daemon-owner-001
    v121-tui-pressure-cancel-001
    v121-tui-input-receipt-001
    v121-tui-terminal-restore-001
    v121-promotion-evidence-001
  ]

  @owner_files %{
    "AllbertAssist.Release.LicensesFinalArtifactTest" =>
      "apps/allbert_assist/test/allbert_assist/release/licenses_final_artifact_test.exs",
    "AllbertAssist.LicensesTest" => "apps/allbert_assist/test/allbert_assist/licenses_test.exs",
    "AllbertAssist.Runtime.Attach.TUIProtocolTest" =>
      "apps/allbert_assist/test/allbert_assist/runtime/attach_tui_protocol_test.exs",
    "AllbertAssist.Settings.SystemIntegrityTest" =>
      "apps/allbert_assist/test/allbert_assist/settings/system_integrity_test.exs",
    "AllbertAssist.CLI.TuiTest" => "apps/allbert_assist/test/allbert_assist/cli/tui_test.exs",
    "AllbertAssist.Runtime.AttachTUIClientTest" =>
      "apps/allbert_assist/test/allbert_assist/runtime/attach_tui_client_test.exs",
    "AllbertAssist.Runtime.TUISessionTest" =>
      "apps/allbert_assist/test/allbert_assist/runtime/tui_session_test.exs",
    "AllbertAssist.Release.PromotionWorkflowContractTest" =>
      "apps/allbert_assist/test/allbert_assist/release/promotion_workflow_contract_test.exs"
  }

  test "v1.2.1 inventory is exact, distinct, and routed to focused behavior owners" do
    rows = EvalInventory.rows_for_milestone(:v121)

    assert MapSet.new(Enum.map(rows, & &1.id)) == MapSet.new(@ids)
    assert length(rows) == 13
    assert Enum.all?(rows, &(length(&1.assert) == 3))
    assert rows |> Enum.map(&MapSet.new(&1.assert)) |> Enum.uniq() |> length() == 13
    assert Enum.all?(rows, &Map.has_key?(@owner_files, &1.test_module))
  end

  test "every v1.2.1 row has an exact AssertBinding call in its owning suite" do
    for row <- EvalInventory.rows_for_milestone(:v121) do
      source =
        GateOwners.read_owned_path!(
          @repo_root,
          Map.fetch!(@owner_files, row.test_module)
        )

      assert source =~ ~s|AssertBinding.check!("#{row.id}"|,
             "row #{row.id} has no AssertBinding.check!/2 call in #{row.test_module}"
    end
  end
end
