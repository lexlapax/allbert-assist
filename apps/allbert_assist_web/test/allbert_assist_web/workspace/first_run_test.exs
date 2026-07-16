defmodule AllbertAssistWeb.Workspace.FirstRunTest do
  @moduledoc """
  Web first-run auto-open decision. Onboarding/profile states open the wizard; a
  completed onboarding with no usable model opens the standalone model repair panel.
  """
  use ExUnit.Case, async: true
  @moduletag :pure_async

  # v0.63 M7.7: part of the web onboarding coverage `release.v063` runs.
  @moduletag :onboarding_wizard

  alias AllbertAssistWeb.Workspace.FirstRun, as: WorkspaceFirstRun

  test "auto-opens while onboarding/profile/model repair is needed" do
    assert WorkspaceFirstRun.auto_open?(state: :onboarding_incomplete)
    assert WorkspaceFirstRun.auto_open?(state: :profile_unreviewed)
    assert WorkspaceFirstRun.auto_open?(state: :first_model_not_ready)
  end

  test "does not auto-open for completion or infra error states" do
    refute WorkspaceFirstRun.auto_open?(state: :product_ready)
    # Infra states (no Home db / schema drift) are a misconfiguration, not first-run.
    refute WorkspaceFirstRun.auto_open?(state: :home_missing)
    refute WorkspaceFirstRun.auto_open?(state: :schema_incompatible)
  end

  test "exposes the onboarding destination string" do
    assert WorkspaceFirstRun.onboard_destination() == "workspace:onboard"
  end

  test "maps first-run states to the right destinations" do
    assert WorkspaceFirstRun.default_destination(state: :onboarding_incomplete) ==
             "workspace:onboard"

    assert WorkspaceFirstRun.default_destination(state: :profile_unreviewed) ==
             "workspace:onboard"

    assert WorkspaceFirstRun.default_destination(state: :first_model_not_ready) ==
             "workspace:models"

    assert WorkspaceFirstRun.default_destination(state: :product_ready) == nil
  end
end
