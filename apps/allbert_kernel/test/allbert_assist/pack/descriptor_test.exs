defmodule AllbertAssist.Pack.DescriptorTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Pack.Descriptor
  alias AllbertAssist.Pack.Kernel

  test "kernel pack exposes its signed-release identity and contributed gate owner" do
    assert %Descriptor{
             schema_version: 1,
             id: "allbert_kernel",
             application: :allbert_kernel,
             application_version: "1.3.2",
             capability_tier: :kernel,
             provenance: %{source: :signed_release, component: "beam-allbert-kernel"},
             registry_order: 0
           } = Kernel.descriptor()

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
          :release_assets
        ] do
      assert [] == apply(Kernel, callback, [])
    end

    assert [%{owner_id: :kernel, application: :allbert_kernel}] = Kernel.test_lanes()
  end

  test "descriptor validation rejects malformed or non-exact callback output" do
    descriptor = Kernel.descriptor()

    assert {:ok, ^descriptor} = Descriptor.validate(descriptor)

    for {field, value} <- [
          schema_version: 2,
          id: "Allbert.Kernel",
          application: nil,
          application_version: "",
          capability_tier: :project,
          provenance: %{source: :signed_release, component: "beam-allbert-kernel", extra: true},
          registry_order: -1
        ] do
      assert {:error, {:invalid_descriptor, ^field}} =
               descriptor
               |> Map.put(field, value)
               |> Descriptor.validate()
    end

    assert {:error, {:invalid_descriptor, :shape}} =
             descriptor
             |> Map.put(:unknown, true)
             |> Descriptor.validate()
  end

  test "descriptor validation requires a canonical owning application" do
    descriptor = %{Kernel.descriptor() | application: :"Allbert-Kernel"}

    assert {:error, {:invalid_descriptor, :application}} = Descriptor.validate(descriptor)
  end

  test "descriptor validation requires a canonical provenance component" do
    descriptor = %{
      Kernel.descriptor()
      | provenance: %{source: :signed_release, component: "beam_allbert_kernel"}
    }

    assert {:error, {:invalid_descriptor, :provenance}} = Descriptor.validate(descriptor)
  end
end
