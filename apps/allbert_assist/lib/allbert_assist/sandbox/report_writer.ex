defmodule AllbertAssist.Sandbox.ReportWriter do
  @moduledoc """
  Writes bounded v0.36 sandbox reports into the disposable bundle report root.
  """

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
      |> json_safe()
      |> Jason.encode!(pretty: true)

    with :ok <- File.write(path, body) do
      {:ok, report}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp json_safe(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {json_safe_key(key), json_safe(val)} end)
    |> Map.new()
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_tuple(value),
    do: inspect(value, limit: 20, printable_limit: 1_000)

  defp json_safe(value), do: value

  defp json_safe_key(key) when is_atom(key), do: key
  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key), do: inspect(key, limit: 10, printable_limit: 200)
end
