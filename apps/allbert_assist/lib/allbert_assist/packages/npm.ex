defmodule AllbertAssist.Packages.Npm do
  @moduledoc """
  npm argv construction for v0.10 package installs.

  The adapter builds argv lists only; it never builds shell strings.
  """

  @spec dry_run_args(map()) :: [String.t()]
  def dry_run_args(spec), do: args(spec, :dry_run)

  @spec install_args(map()) :: [String.t()]
  def install_args(spec), do: args(spec, :install)

  @spec argv_preview(map(), [String.t()]) :: [String.t()]
  def argv_preview(spec, args) do
    [spec.profile.executable | args]
  end

  defp args(spec, mode) do
    spec.profile.args_prefix ++
      ["install"] ++
      package_specs(spec) ++
      save_args(spec.save_mode) ++
      common_safety_args(spec) ++
      mode_args(mode) ++
      profile_args(spec, mode)
  end

  defp package_specs(spec), do: Enum.map(spec.packages, & &1.spec)

  defp save_args(:prod), do: ["--save-prod"]
  defp save_args(:dev), do: ["--save-dev"]
  defp save_args(:optional), do: ["--save-optional"]
  defp save_args(:peer), do: ["--save-peer"]
  defp save_args(:no_save), do: ["--no-save"]

  defp common_safety_args(spec) do
    [
      "--json",
      "--save-exact",
      "--no-fund",
      "--no-audit"
    ]
    |> maybe_add(not spec.profile.lifecycle_scripts_allowed?, "--ignore-scripts")
    |> maybe_add(not spec.profile.git_dependencies_allowed?, "--allow-git=none")
  end

  defp mode_args(:dry_run), do: ["--dry-run"]
  defp mode_args(:install), do: []

  defp profile_args(spec, :dry_run), do: spec.profile.plan_args
  defp profile_args(spec, :install), do: spec.profile.install_args

  defp maybe_add(args, true, arg), do: args ++ [arg]
  defp maybe_add(args, false, _arg), do: args
end
