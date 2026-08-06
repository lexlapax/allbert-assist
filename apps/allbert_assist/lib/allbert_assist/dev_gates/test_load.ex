defmodule AllbertAssist.DevGates.TestLoad do
  @moduledoc """
  Owner-CWD zero-execution test-load contract for preflight.

  Loading is intentionally separate from lane-tag and manifest reconciliation:
  a correctly classified file can still assume the wrong test helper or CWD.
  """

  alias AllbertAssist.DevGates.TestMetrics

  def command(relative_files) when is_list(relative_files) and relative_files != [] do
    ["test", "--exclude", "test" | relative_files]
  end

  def result(label, output, status) when is_binary(label) and is_binary(output) do
    totals = TestMetrics.sum_exunit_totals(output)

    cond do
      status != 0 -> {:error, label, status, output}
      totals.tests != 0 -> {:error, label, 1, output <> "\nowner-CWD load executed tests"}
      true -> {:ok, label, output}
    end
  end
end
