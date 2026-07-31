defmodule AllbertAssist.FirstRun.PresentationTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.FirstRun.Presentation

  @rows [
    {%{state: :auto_enabled, model_state: :local_ready}, nil},
    {%{state: :sticky_disabled, model_state: :local_ready}, nil},
    {%{state: :needs_model, model_state: :model_missing}, :pull_curated_model},
    {%{state: :needs_model, model_state: :runtime_unhealthy}, :repair_runtime},
    {%{state: :nothing_detected, model_state: :runtime_missing}, :install_runtime},
    {%{state: :below_floor, model_state: :below_hardware_floor}, :configure_hosted_provider},
    {%{state: :enabled_unavailable, model_state: :runtime_missing}, :select_model},
    {%{state: :enabled_unavailable, model_state: :local_ready}, :select_model},
    {%{state: :enabled_unavailable, model_state: :model_missing}, :select_model},
    {%{state: :enabled_unavailable, model_state: :runtime_unhealthy}, :select_model},
    {%{state: :enabled_unavailable, model_state: :below_hardware_floor}, :select_model}
  ]

  test "every detect-state presentation has at most one primary CTA on every surface" do
    for {result, expected_cta} <- @rows, surface <- [:web, :tui, :cli] do
      presentation = Presentation.for(result, surface)
      assert length(presentation.primary_ctas) <= 1
      assert List.first(presentation.primary_ctas) == expected_cta
      assert presentation.readiness == Presentation.readiness(result)
      refute presentation.message =~ inspect(result.model_state)
    end
  end

  test "DirectAnswer readiness stays separate from a ready global substrate" do
    result = %{state: :enabled_unavailable, model_state: :local_ready}

    assert Presentation.substrate(:local_ready) == :ready
    assert Presentation.readiness(result) == :needs_selection
  end

  test "surface presentation retains sticky task availability" do
    available = %{
      state: :sticky_disabled,
      model_state: :model_missing,
      availability: :available
    }

    unavailable = %{
      state: :sticky_disabled,
      model_state: :local_ready,
      availability: :unavailable
    }

    assert Presentation.for(available, :cli).readiness == :ready
    assert Presentation.for(unavailable, :cli).readiness == :needs_selection
  end
end
