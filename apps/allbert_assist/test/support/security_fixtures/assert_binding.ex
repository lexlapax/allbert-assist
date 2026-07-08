defmodule AllbertAssist.SecurityFixtures.AssertBinding do
  @moduledoc """
  v0.63 M7.7 — bind an eval row's declared `assert:` atoms to the test that proves them.

  Before this, `EvalInventory` `assert:` atoms were decorative: a row could claim
  assertions no test performed. `check!/2` closes that gap — an owning test calls it
  with the exact set of atoms it just asserted, and it fails unless that set equals the
  row's inventory `assert:` list. So an atom can only ship if a test enumerates (and,
  right above the call, actually proves) it, and a row can't drift from its tests.

  Usage inside an owning test, after the behavioural assertions:

      AssertBinding.check!("provider-switch-no-config-edit-001", [:switch_writes_settings, :no_file_edit])
  """
  import ExUnit.Assertions

  alias AllbertAssist.SecurityFixtures.EvalInventory

  @doc "Assert the atoms a test proved match exactly the row's declared `assert:` atoms."
  @spec check!(String.t(), [atom()]) :: :ok
  def check!(row_id, proved_atoms) when is_binary(row_id) and is_list(proved_atoms) do
    row = EvalInventory.row!(row_id)

    assert MapSet.new(row.assert) == MapSet.new(proved_atoms),
           "row #{row_id}: inventory assert atoms #{inspect(Enum.sort(row.assert))} " <>
             "do not match the atoms the test proved #{inspect(Enum.sort(proved_atoms))}"

    :ok
  end
end
