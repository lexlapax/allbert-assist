defmodule AllbertAssist.Security.V063SweepEvalTest do
  @moduledoc """
  v0.63 Guided Onboarding & Profiles sweep (ADR 0069 / 0075).

  Inventory completeness / shape / ownership routing for the 16 `:v063` eval rows,
  plus the sweep-owned ADR-acceptance rows. The behavioural rows are asserted by their
  owning proof tests (`AllbertAssist.Onboarding.SecurityEvalTest` /
  `AllbertAssist.Onboarding.FlowEvalTest`), routed below.
  """
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.SecurityFixtures.EvalInventory

  @eval_ids ~w(
    onboarding-no-authority-from-profiles-001
    onboarding-no-secret-leak-001
    onboarding-settings-central-only-writes-001
    profile-seeds-defaults-only-001
    provider-key-masked-vault-entry-redaction-001
    provider-env-tier-read-only-001
    provider-switch-no-config-edit-001
    profile-apply-explicit-review-001
    onboarding-noninteractive-authorize-no-bypass-001
    onboarding-reset-preserves-home-001
    wizard-shared-flow-no-surface-fork-001
    wizard-operator-readiness-copy-001
    trust-spine-surfaced-001
    quickstart-fastest-first-chat-001
    adr-0069-accepted-001
    adr-0075-accepted-001
  )

  @owners %{
    "onboarding-no-authority-from-profiles-001" => "AllbertAssist.Onboarding.SecurityEvalTest",
    "onboarding-no-secret-leak-001" => "AllbertAssist.Onboarding.SecurityEvalTest",
    "onboarding-settings-central-only-writes-001" => "AllbertAssist.Onboarding.SecurityEvalTest",
    "profile-seeds-defaults-only-001" => "AllbertAssist.Onboarding.SecurityEvalTest",
    "provider-key-masked-vault-entry-redaction-001" =>
      "AllbertAssist.Onboarding.SecurityEvalTest",
    "provider-env-tier-read-only-001" => "AllbertAssist.Onboarding.SecurityEvalTest",
    "provider-switch-no-config-edit-001" => "AllbertAssist.Onboarding.SecurityEvalTest",
    "profile-apply-explicit-review-001" => "AllbertAssist.Onboarding.SecurityEvalTest",
    "onboarding-noninteractive-authorize-no-bypass-001" =>
      "AllbertAssist.Onboarding.SecurityEvalTest",
    "onboarding-reset-preserves-home-001" => "AllbertAssist.Onboarding.SecurityEvalTest",
    "wizard-shared-flow-no-surface-fork-001" => "AllbertAssist.Onboarding.FlowEvalTest",
    "wizard-operator-readiness-copy-001" => "AllbertAssist.Onboarding.FlowEvalTest",
    "trust-spine-surfaced-001" => "AllbertAssist.Onboarding.FlowEvalTest",
    "quickstart-fastest-first-chat-001" => "AllbertAssist.Onboarding.FlowEvalTest",
    "adr-0069-accepted-001" => "AllbertAssist.Security.V063SweepEvalTest",
    "adr-0075-accepted-001" => "AllbertAssist.Security.V063SweepEvalTest"
  }

  @repo_root Path.expand("../../../../", __DIR__)

  test "v0.63 eval inventory rows are complete and routed to their owning tests" do
    rows = EvalInventory.rows_for_milestone(:v063)
    row_ids = Enum.map(rows, & &1.id)
    rows_by_id = Map.new(rows, &{&1.id, &1})

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert length(row_ids) == 16
    assert Enum.all?(rows, &(&1.milestone == :v063))

    for {id, owner} <- @owners do
      assert rows_by_id[id].test_module == owner, "row #{id} routed to the wrong owning test"
    end

    IO.puts("v063-inventory-complete status=pass rows=16 owners=routed")
  end

  test "v0.63 sweep rows encode concrete pass criteria" do
    rows = EvalInventory.rows_for_milestone(:v063)

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert) and row.assert != []
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
    end
  end

  test "adr-0069-accepted-001: ADR 0069 is Accepted (v0.63)" do
    adr = read!("docs/adr/0069-operator-onboarding-flow.md")
    assert adr =~ "Status: Accepted (v0.63)"

    IO.puts("adr-0069-accepted-001 status=pass adr=accepted")
  end

  test "adr-0075-accepted-001: ADR 0075 is Accepted (v0.63)" do
    adr = read!("docs/adr/0075-user-category-settings-profiles.md")
    assert adr =~ "Status: Accepted (v0.63)"

    IO.puts("adr-0075-accepted-001 status=pass adr=accepted")
  end

  defp read!(relative) do
    @repo_root |> Path.join(relative) |> File.read!()
  end
end
