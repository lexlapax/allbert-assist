defmodule AllbertAssist.DevGates.V14M1RegistryShadowParityTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.DevGates.V14M1RegistryShadowParity
  alias AllbertAssist.Pack.Projection
  alias AllbertAssist.Pack.Projection.Closed

  @fixture Path.expand(
             "../../../../allbert_kernel/test/fixtures/v1.4/pack_row_schema_contract.json",
             __DIR__
           )

  test "generated row-schema contract fixture is exact and self-validating" do
    live = V14M1RegistryShadowParity.row_schema_contract_fixture()
    frozen = V14M1RegistryShadowParity.load_row_schema_contract_fixture!()

    assert V14M1RegistryShadowParity.row_schema_contract_fixture_path() == @fixture

    assert Map.keys(live) |> Enum.sort() ==
             ~w[normalization schema_contract schema_contract_sha256 schema_version]

    assert live["schema_version"] == 1
    assert live["normalization"] == "v14_pack_row_schema_contract_v1"
    assert is_list(live["schema_contract"])
    assert live["schema_contract_sha256"] =~ ~r/^[0-9a-f]{64}$/
    assert frozen == live
    assert :ok = V14M1RegistryShadowParity.check_row_schema_contract_fixture!()
  end

  test "source Pack projection is sealed to the complete application closure" do
    # v1.4 M9 extracted the notes_files pack, so the closure spans a third
    # descriptor-bearing application and the rows are ordered by registry_order:
    # kernel 0, residual 100, notes_files 200.
    assert %Closed{
             schema_version: 1,
             closed_applications: [
               :allbert_kernel,
               :allbert_assist,
               :allbert_notes_files,
               :allbert_composition,
               :allbert_assist_web
             ],
             pack_applications: [:allbert_kernel, :allbert_assist, :allbert_notes_files],
             rows: [kernel, residual, notes_files],
             projection_sha256: projection_sha256,
             closure_sha256: closure_sha256
           } = closed = V14M1RegistryShadowParity.source_closed_projection!()

    assert kernel.application == :allbert_kernel
    assert residual.application == :allbert_assist
    assert notes_files.application == :allbert_notes_files
    assert notes_files.registry_order == 200
    assert notes_files.startup_role == :native_passive
    assert kernel.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert residual.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert notes_files.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert projection_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert closure_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert :ok = Projection.validate_closed(closed)
  end
end
