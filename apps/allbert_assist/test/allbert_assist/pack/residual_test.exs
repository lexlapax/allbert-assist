defmodule AllbertAssist.Pack.ResidualTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Pack.Descriptor
  alias AllbertAssist.Pack.Residual

  test "residual application exposes its native-pack identity and inert contribution ABI" do
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
          :settings_fragments,
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
          :release_assets,
          :test_lanes
        ] do
      assert [] == apply(Residual, callback, [])
    end
  end
end
