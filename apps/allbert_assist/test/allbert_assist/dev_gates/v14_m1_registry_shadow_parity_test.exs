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
    # v1.4 M13 completed the extraction, so the closure spans fifteen
    # descriptor-bearing applications ordered by registry_order. The seven channel
    # packs are `native_effectful` because M13 also moved their adapters onto
    # their own effect supervisors; everything else that is not the kernel or the
    # residual is passive.
    assert %Closed{
             schema_version: 1,
             closed_applications: [
               :allbert_kernel,
               :allbert_assist,
               :allbert_notes_files,
               :allbert_telegram,
               :allbert_email,
               :allbert_research,
               :allbert_browser,
               :allbert_discord,
               :allbert_matrix,
               :allbert_signal,
               :allbert_slack,
               :allbert_tui,
               :allbert_whatsapp,
               :allbert_artifacts,
               :stocksage,
               :allbert_composition,
               :allbert_assist_web
             ],
             pack_applications: [
               :allbert_kernel,
               :allbert_assist,
               :allbert_notes_files,
               :allbert_telegram,
               :allbert_email,
               :allbert_research,
               :allbert_browser,
               :allbert_discord,
               :allbert_matrix,
               :allbert_signal,
               :allbert_slack,
               :allbert_tui,
               :allbert_whatsapp,
               :allbert_artifacts,
               :stocksage
             ],
             rows: [
               kernel,
               residual,
               notes_files,
               telegram,
               email,
               research,
               browser,
               discord,
               matrix,
               signal,
               slack,
               tui,
               whatsapp,
               artifacts,
               stocksage
             ],
             projection_sha256: projection_sha256,
             closure_sha256: closure_sha256
           } = closed = V14M1RegistryShadowParity.source_closed_projection!()

    assert kernel.application == :allbert_kernel
    assert kernel.registry_order == 0
    assert kernel.startup_role == :kernel_prerequisite
    assert kernel.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert residual.application == :allbert_assist
    assert residual.registry_order == 100
    assert residual.startup_role == :native_effectful
    assert residual.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert notes_files.application == :allbert_notes_files
    assert notes_files.registry_order == 200
    assert notes_files.startup_role == :native_passive
    assert notes_files.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert telegram.application == :allbert_telegram
    assert telegram.registry_order == 300
    assert telegram.startup_role == :native_effectful
    assert telegram.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert email.application == :allbert_email
    assert email.registry_order == 400
    assert email.startup_role == :native_effectful
    assert email.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert research.application == :allbert_research
    assert research.registry_order == 500
    assert research.startup_role == :native_passive
    assert research.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert browser.application == :allbert_browser
    assert browser.registry_order == 600
    assert browser.startup_role == :native_passive
    assert browser.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert discord.application == :allbert_discord
    assert discord.registry_order == 700
    assert discord.startup_role == :native_effectful
    assert discord.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert matrix.application == :allbert_matrix
    assert matrix.registry_order == 800
    assert matrix.startup_role == :native_effectful
    assert matrix.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert signal.application == :allbert_signal
    assert signal.registry_order == 900
    assert signal.startup_role == :native_effectful
    assert signal.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert slack.application == :allbert_slack
    assert slack.registry_order == 1000
    assert slack.startup_role == :native_effectful
    assert slack.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert tui.application == :allbert_tui
    assert tui.registry_order == 1100
    assert tui.startup_role == :native_passive
    assert tui.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert whatsapp.application == :allbert_whatsapp
    assert whatsapp.registry_order == 1200
    assert whatsapp.startup_role == :native_effectful
    assert whatsapp.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert artifacts.application == :allbert_artifacts
    assert artifacts.registry_order == 1300
    assert artifacts.startup_role == :native_passive
    assert artifacts.app_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert stocksage.application == :stocksage
    assert stocksage.registry_order == 1400
    assert stocksage.startup_role == :native_passive
    assert stocksage.app_sha256 =~ ~r/^[0-9a-f]{64}$/

    assert projection_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert closure_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert :ok = Projection.validate_closed(closed)
  end
end
