defmodule AllbertAssistWeb.Workspace.FirstRunTest do
  @moduledoc """
  v0.63 M5 — the web first-run auto-open decision. Auto-open takes over the canvas
  only while onboarding is not yet completed (`:onboarding_incomplete`/
  `:profile_unreviewed`), never merely because the model isn't set up yet.
  """
  use ExUnit.Case, async: true

  alias AllbertAssistWeb.Workspace.FirstRun, as: WorkspaceFirstRun

  test "auto-opens while onboarding is incomplete or profile is unreviewed" do
    assert WorkspaceFirstRun.auto_open?(state: :onboarding_incomplete)
    assert WorkspaceFirstRun.auto_open?(state: :profile_unreviewed)
  end

  test "does not auto-open for completion, a missing model, or infra error states" do
    refute WorkspaceFirstRun.auto_open?(state: :product_ready)
    refute WorkspaceFirstRun.auto_open?(state: :first_model_not_ready)
    # Infra states (no Home db / schema drift) are a misconfiguration, not first-run.
    refute WorkspaceFirstRun.auto_open?(state: :home_missing)
    refute WorkspaceFirstRun.auto_open?(state: :schema_incompatible)
  end

  test "exposes the onboarding destination string" do
    assert WorkspaceFirstRun.onboard_destination() == "workspace:onboard"
  end
end
