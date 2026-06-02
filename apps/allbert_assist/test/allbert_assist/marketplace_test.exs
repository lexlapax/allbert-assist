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
  end
end
