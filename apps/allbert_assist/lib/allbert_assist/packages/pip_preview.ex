defmodule AllbertAssist.Packages.PipPreview do
  @moduledoc """
  Preview-only pip argv construction for v0.10.

  v0.10 does not execute pip. It records the bounded preview shape so the
  stricter hash, wheel, and virtualenv policy can be implemented later.
  """

  @preview_note "pip execution requires strict hash and binary policy; preview only in v0.10."

  @spec preview_args(map()) :: [String.t()]
  def preview_args(spec) do
    spec.profile.args_prefix ++
      ["install", "--dry-run", "--ignore-installed", "--quiet", "--report", "-"] ++
      Enum.map(spec.packages, & &1.spec) ++
      spec.profile.plan_args
  end

  @spec preview_note() :: String.t()
  def preview_note, do: @preview_note
end
