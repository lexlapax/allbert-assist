defmodule Mix.Tasks.Allbert.Sandbox do
  @moduledoc """
  Inspect the v0.36 Elixir/OTP sandbox posture.

  ## Usage

      mix allbert.sandbox doctor
  """

  use Mix.Task

  alias AllbertAssist.Sandbox

  @shortdoc "Inspect the v0.36 Elixir/OTP sandbox posture"

  @impl true
  def run(["doctor"]) do
    Mix.Task.run("app.start")

    Sandbox.doctor()
    |> print_doctor()

    :ok
  end

  def run(_args), do: Mix.raise(usage())

  defp print_doctor(report) do
    Mix.shell().info("Status: #{report.status}")
    Mix.shell().info("Enabled: #{report.enabled?}")
    Mix.shell().info("Configured backend: #{report.configured_backend}")
    Mix.shell().info("Resolved backend: #{report.resolved_backend || "none"}")
    Mix.shell().info("Image: #{report.settings.image}")
    Mix.shell().info("Network: #{report.settings.network}")
    Mix.shell().info("Bundles: #{report.roots.bundles}")
    Mix.shell().info("Reports: #{report.roots.reports}")

    Enum.each(report.candidates, fn candidate ->
      Mix.shell().info(
        "Candidate #{candidate.id}: #{candidate.status} #{inspect(Map.get(candidate, :reason))}"
      )
    end)

    Enum.each(report.diagnostics, fn diagnostic ->
      Mix.shell().info("Diagnostic: #{inspect(diagnostic)}")
    end)
  end

  defp usage do
    """
    Usage:
      mix allbert.sandbox doctor
    """
  end
end
