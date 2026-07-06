defmodule AllbertAssist.CLI.Areas.Render do
  @moduledoc """
  Tiny shared rendering helpers for the release-safe `CLI.Areas.*` modules
  (v0.62 M8.7). Each area's `dispatch/2` returns `{output, exit_code}`; these
  keep the exit-code convention consistent: 0 ok, 1 error, 2 usage/operand.
  """

  @spec ok([String.t()] | String.t()) :: {String.t(), 0}
  def ok(lines), do: {join(lines), 0}

  @spec error([String.t()] | String.t()) :: {String.t(), 1}
  def error(lines), do: {join(lines), 1}

  @spec usage([String.t()] | String.t()) :: {String.t(), 2}
  def usage(lines), do: {join(lines), 2}

  defp join(lines) when is_list(lines), do: lines |> Enum.join("\n") |> String.trim_trailing()
  defp join(line) when is_binary(line), do: String.trim_trailing(line)
end
