defmodule AllbertAssist.Sandbox.ReportWriter do
  @moduledoc """
  Writes bounded v0.36 sandbox reports into the disposable bundle report root.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.Report

  @spec write(Bundle.t(), Report.t()) :: {:ok, Report.t()} | {:error, term()}
  def write(%Bundle{} = bundle, %Report{} = report) do
    File.mkdir_p!(bundle.reports_path)

    path =
      Path.join(
        bundle.reports_path,
        "#{report.backend || "unknown"}-#{System.unique_integer([:positive])}.json"
      )

    report = %{report | report_path: path}

    body =
      report
      |> Report.to_map()
      |> redact_paths()
      |> Redactor.redact(:sandbox_trial)
      |> Jason.encode!(pretty: true)

    with :ok <- File.write(path, body) do
      {:ok, report}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp redact_paths(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {key, redact_paths(val)} end)
    |> Map.new()
  end

  defp redact_paths(value) when is_list(value), do: Enum.map(value, &redact_paths/1)

  defp redact_paths(value) when is_binary(value) do
    home = Paths.home()
    String.replace(value, home, "<ALLBERT_HOME>")
  end

  defp redact_paths(value), do: value
end
