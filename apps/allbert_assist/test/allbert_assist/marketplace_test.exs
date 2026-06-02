defmodule AllbertAssist.MarketplaceTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Actions.Marketplace.Doctor, as: MarketplaceDoctor
  alias AllbertAssist.Marketplace

  test "Marketplace facade and doctor action are inert in M1" do
    assert {:error, {:not_implemented_yet, doctor}} = Marketplace.doctor()
    assert doctor.endpoint_kind == :local_endpoint
    assert doctor.credential_ok == nil
    refute doctor.endpoint_ok
    assert doctor.model_available == :unknown
    assert doctor.redacted_host == "local"
    assert doctor.error_category == :unknown_marketplace_doctor_error
    assert doctor.live_check_status == :not_implemented
    assert [%{code: :not_implemented_yet}] = doctor.diagnostics

    assert {:error, {:not_implemented_yet, ^doctor}} = MarketplaceDoctor.run(%{}, %{})
    assert {:error, :not_implemented_yet} = Marketplace.list_entries()
    assert {:error, :not_implemented_yet} = Marketplace.inspect_entry("allbert/write-weekly-note")

    assert {:error, :not_implemented_yet} =
             Marketplace.install_bundle("allbert/write-weekly-note")

    assert {:error, :not_implemented_yet} =
             Marketplace.rollback_install("allbert/write-weekly-note")

    assert {:error, :not_implemented_yet} = Marketplace.list_installed()

    assert {:error, :not_implemented_yet} =
             Marketplace.verify_bundle_hash("allbert/write-weekly-note")
  end
end
