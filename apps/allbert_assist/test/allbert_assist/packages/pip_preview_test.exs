defmodule AllbertAssist.Packages.PipPreviewTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Packages.ManagerProfile
  alias AllbertAssist.Packages.PipPreview

  test "builds preview-only pip dry-run argv" do
    spec = %{
      manager: :pip,
      packages: [%{spec: "requests==2.31.0"}],
      profile: %ManagerProfile{executable: "pip", args_prefix: [], plan_args: []}
    }

    assert PipPreview.preview_args(spec) == [
             "install",
             "--dry-run",
             "--ignore-installed",
             "--quiet",
             "--report",
             "-",
             "requests==2.31.0"
           ]

    assert PipPreview.preview_note() =~ "preview only in v0.10"
  end
end
