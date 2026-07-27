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
    {%{state: :enabled_unavailable, model_state: :runtime_missing}, :install_runtime},
    {%{state: :enabled_unavailable, model_state: :model_missing}, :pull_curated_model},
    {%{state: :enabled_unavailable, model_state: :runtime_unhealthy}, :repair_runtime},
    {%{state: :enabled_unavailable, model_state: :below_hardware_floor},
     :configure_hosted_provider}
  ]

  test "every detect-state presentation has at most one primary CTA on every surface" do
    for {result, expected_cta} <- @rows, surface <- [:web, :tui, :cli] do
      presentation = Presentation.for(result, surface)
      assert length(presentation.primary_ctas) <= 1
      assert List.first(presentation.primary_ctas) == expected_cta
      refute presentation.message =~ inspect(result.model_state)
    end
  end
end
