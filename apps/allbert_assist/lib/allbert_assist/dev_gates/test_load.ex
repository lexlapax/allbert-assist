defmodule AllbertAssist.DevGates.TestLoad do
  @moduledoc """
  Owner-CWD zero-execution test-load contract for preflight.

  Loading is intentionally separate from lane-tag and manifest reconciliation:
  a correctly classified file can still assume the wrong test helper or CWD.
  """

  alias AllbertAssist.DevGates.TestMetrics

  def command(relative_files) when is_list(relative_files) and relative_files != [] do
    # Preflight has already completed one forced warnings-as-errors compile.
    # Every owner loads in parallel against that exact artifact set; allowing
    # any child to compile can replace shared umbrella beams while another
    # owner is booting them.
    ["test", "--no-compile", "--exclude", "test" | relative_files]
  end

  # v1.4 M13.4. Loading is the only place a test-tree compiler warning becomes
  # visible to a gate. Preflight's `forced_compile` and the release gate's
  # `compile_warnings_as_errors` both compile `lib` only, so an unaliased
  # module or an unused alias in a test file is invisible until a suite runs.
  # M13.4's census traced twenty-eight failures to exactly that blind spot, and
  # the defects behind fifteen of them had already reached main. Loading
  # already prints the warnings; this is what makes them fail.
  #
  # Exactly one line is allowed through, and it is matched on its own text
  # rather than by a prefix so a real warning cannot shelter behind it: Mix
  # emits a `:test_load_filters` notice whenever a run names explicit files,
  # which every owner load does by construction.
  @allowed_warning "do not match any of the configured"

  def result(label, output, status) when is_binary(label) and is_binary(output) do
    totals = TestMetrics.sum_exunit_totals(output)
    warnings = compiler_warnings(output)

    cond do
      status != 0 ->
        {:error, label, status, output}

      totals.tests != 0 ->
        {:error, label, 1, output <> "\nowner-CWD load executed tests"}

      warnings != [] ->
        {:error, label, 1,
         output <>
           "\nowner-CWD load emitted test-tree compiler warnings:\n" <>
           Enum.join(warnings, "\n")}

      true ->
        {:ok, label, output}
    end
  end

  defp compiler_warnings(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ ~r/^\s*warning:/))
    |> Enum.reject(&String.contains?(&1, @allowed_warning))
  end
end
