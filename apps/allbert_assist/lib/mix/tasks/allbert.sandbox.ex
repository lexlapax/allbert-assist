defmodule Mix.Tasks.Allbert.Sandbox do
  @moduledoc """
  Inspect the v0.36 Elixir/OTP sandbox posture.

  ## Usage

      mix allbert.sandbox doctor
  """

  use Mix.Task

  alias AllbertAssist.Sandbox
  alias AllbertAssist.Sandbox.Image

  @shortdoc "Inspect the v0.36 Elixir/OTP sandbox posture"

  @impl true
  def run(["doctor"]) do
    Mix.Task.run("app.start")

    Sandbox.doctor(operator_id: "mix")
    |> print_doctor()

    :ok
  end

  def run(["image", "build" | args]) do
    Mix.Task.run("app.start")

    args
    |> image_opts()
    |> Image.build()
    |> print_image_report_or_raise("build")
  end

  def run(["image", "verify" | args]) do
    Mix.Task.run("app.start")

    args
    |> image_opts()
    |> Image.verify()
    |> print_image_report_or_raise("verify")
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

  defp print_image_report_or_raise({:ok, report}, _operation) do
    print_image_report(report)
    :ok
  end

  defp print_image_report_or_raise({:error, report}, operation) do
    print_image_report(report)
    Mix.raise("sandbox image #{operation} failed: #{inspect(report.diagnostics)}")
  end

  defp print_image_report(report) do
    Mix.shell().info("Status: #{report.status}")
    Mix.shell().info("Operation: #{report.operation}")
    Mix.shell().info("Image: #{report.image}")
    Mix.shell().info("Report: #{report.report_path}")

    Enum.each(report.diagnostics, fn diagnostic ->
      Mix.shell().info("Diagnostic: #{inspect(diagnostic)}")
    end)
  end

  defp image_opts(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          image: :string,
          base: :string,
          no_pull_base: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      Mix.raise(usage())
    end

    []
    |> maybe_put(:image, opts[:image])
    |> maybe_put(:base_image, opts[:base])
    |> Keyword.put(:pull_base?, !Keyword.get(opts, :no_pull_base, false))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    """
    Usage:
      mix allbert.sandbox doctor
      mix allbert.sandbox image build [--image IMAGE] [--base BASE_IMAGE] [--no-pull-base]
      mix allbert.sandbox image verify [--image IMAGE]
    """
  end
end
