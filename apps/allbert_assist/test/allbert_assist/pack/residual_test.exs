defmodule AllbertAssist.Pack.ResidualTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Pack.Descriptor
  alias AllbertAssist.Pack.Residual
  alias AllbertAssist.Settings.FragmentOwner

  test "residual application exposes its native-pack identity and unused contribution ABI" do
    assert %Descriptor{
             schema_version: 1,
             id: "allbert_assist",
             application: :allbert_assist,
             application_version: "1.3.2",
             capability_tier: :native,
             provenance: %{source: :signed_release, component: "beam-allbert-assist"},
             registry_order: 100
           } = Residual.descriptor()

    for callback <- [
          :apps,
          :actions,
          :settings_migrations,
          :channels,
          :surfaces,
          :skill_roots,
          :home_roots,
          :jobs,
          :stores,
          :prompt_rules,
          :intent_descriptors,
          :cli_groups,
          :release_assets
        ] do
      assert [] == apply(Residual, callback, [])
    end

    # v1.4 M13 emptied this list down to :core. notes_files left at M9, telegram
    # and email at M12, and M13 took the remaining ten -- the residual answers
    # only for the code it still compiles, and every other owner declares its own
    # lane through its Pack.test_lanes/0.
    assert Enum.map(Residual.test_lanes(), & &1.owner_id) == [:core]
  end

  test "residual application exposes every compiled settings fragment owner" do
    owners = Residual.settings_fragments()

    assert [_owner | _owners] = owners
    assert owners == Enum.sort(owners)
    assert Enum.all?(owners, &FragmentOwner.owner_module?/1)
    assert {:ok, ^owners} = FragmentOwner.compiled_owner_modules(:allbert_assist)
  end
end
