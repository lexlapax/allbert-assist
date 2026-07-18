defmodule AllbertAssist.Confirmations.PackageInstallMetadata do
  @moduledoc """
  Operator-facing package-install metadata extracted from confirmation records.

  Formatting stays separate from policy, storage, and execution. Package
  approvals still resume only through `approve_confirmation`.
  """

  alias AllbertAssist.Maps

  @doc "Return true when a confirmation targets v0.10 package execution."
  @spec package_confirmation?(map()) :: boolean()
  def package_confirmation?(confirmation) when is_map(confirmation) do
    get_in(confirmation, ["target_action", "name"]) == "run_package_install"
  end

  @doc "Return compact package install details for CLI and LiveView surfaces."
  @spec package_details(map()) :: [String.t()]
  def package_details(confirmation) when is_map(confirmation) do
    if package_confirmation?(confirmation) do
      package_detail_lines(params_summary(confirmation))
    else
      []
    end
  end

  @doc "Return compact target result details for resolved package confirmations."
  @spec result_details(map()) :: [String.t()]
  def result_details(confirmation) when is_map(confirmation) do
    result = target_result(confirmation)

    if package_confirmation?(confirmation) and result != %{} do
      result_detail_lines(result, target_status(confirmation))
    else
      []
    end
  end

  @doc "Return all available package/result lines for a package confirmation."
  @spec lines(map()) :: [String.t()]
  def lines(confirmation) when is_map(confirmation) do
    package_details(confirmation) ++ result_details(confirmation)
  end

  def lines(_confirmation), do: []

  @doc "Return package install/plan lines from a runtime action map."
  @spec action_lines(map() | nil) :: [String.t()]
  def action_lines(action) when is_map(action) do
    if action_name(action) in ["plan_package_install", "run_package_install"] do
      package_detail_lines(
        field(action, "package_install") || field(action, "install_plan") || %{}
      ) ++ result_detail_lines(field(action, "result") || %{})
    else
      []
    end
  end

  def action_lines(_action), do: []

  defp package_detail_lines(summary) when is_map(summary) do
    [
      {"Manager", field(summary, "manager")},
      {"Packages", packages_text(field(summary, "packages"))},
      {"Target root", field(summary, "resolved_target_root") || field(summary, "target_root")},
      {"Dry-run argv", argv_text(field(summary, "dry_run_argv"))},
      {"Execution argv", argv_text(field(summary, "execution_argv_preview"))},
      {"Execution available", field(summary, "execution_available?")},
      {"Timeout", ms_text(field(summary, "timeout_ms"))},
      {"Output cap", bytes_text(field(summary, "max_output_bytes"))},
      {"Warnings", packages_text(field(summary, "warnings"))},
      {"Denial", denial_text(field(summary, "denial_reason"))}
    ]
    |> reject_blank_values()
    |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)
  end

  defp package_detail_lines(_summary), do: []

  defp result_detail_lines(result, fallback_status \\ nil)

  defp result_detail_lines(result, fallback_status) when is_map(result) do
    [
      {"Result", field(result, "status") || fallback_status},
      {"Exit", field(result, "exit_status")},
      {"Timed out", field(result, "timed_out?")},
      {"Truncated", field(result, "truncated?")},
      {"Output bytes", field(result, "output_bytes")},
      {"Output preview", output_preview(result)}
    ]
    |> reject_blank_values()
    |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)
  end

  defp result_detail_lines(_result, _fallback_status), do: []

  defp params_summary(confirmation), do: Map.get(confirmation, "params_summary", %{}) || %{}

  defp target_result(confirmation) do
    get_in(confirmation, ["operator_resolution", "target_result"]) || %{}
  end

  defp target_status(confirmation) do
    get_in(confirmation, ["operator_resolution", "target_status"])
  end

  defp packages_text(values) when is_list(values), do: Enum.join(values, ", ")
  defp packages_text(_values), do: nil

  defp argv_text(values) when is_list(values), do: Enum.join(values, " ")
  defp argv_text(_values), do: nil

  defp ms_text(nil), do: nil
  defp ms_text(value), do: "#{value}ms"

  defp bytes_text(nil), do: nil
  defp bytes_text(value), do: "#{value} bytes"

  defp denial_text(value) when value in [nil, "nil", ""], do: nil
  defp denial_text(value), do: inspect(value)

  defp output_preview(result) do
    result
    |> field("stdout_preview")
    |> case do
      value when value in [nil, ""] -> nil
      value -> String.trim_trailing(to_string(value))
    end
  end

  defp reject_blank_values(items) do
    Enum.reject(items, fn {_label, value} -> blank?(value) end)
  end

  defp blank?(value), do: value in [nil, ""]

  defp field(map, key) when is_map(map), do: Maps.field_truthy(map, key)

  defp action_name(action), do: field(action, "name")
end
