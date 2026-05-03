defmodule AllbertAssist.Confirmations.SkillScriptMetadata do
  @moduledoc """
  Operator-facing skill script metadata extracted from confirmation records.

  This is a formatting helper only. Policy decisions, execution, and approval
  semantics stay behind registered actions.
  """

  @doc "Return true when a confirmation targets v0.09 skill script execution."
  @spec script_confirmation?(map()) :: boolean()
  def script_confirmation?(confirmation) when is_map(confirmation) do
    get_in(confirmation, ["target_action", "name"]) == "run_skill_script"
  end

  @doc "Return compact script details for CLI and LiveView surfaces."
  @spec script_details(map()) :: [String.t()]
  def script_details(confirmation) when is_map(confirmation) do
    if script_confirmation?(confirmation) do
      script_detail_lines(params_summary(confirmation))
    else
      []
    end
  end

  @doc "Return compact target result details for resolved script confirmations."
  @spec result_details(map()) :: [String.t()]
  def result_details(confirmation) when is_map(confirmation) do
    result = target_result(confirmation)

    if script_confirmation?(confirmation) and result != %{} do
      result_detail_lines(result, target_status(confirmation))
    else
      []
    end
  end

  @doc "Return all available script/result lines for a skill script confirmation."
  @spec lines(map()) :: [String.t()]
  def lines(confirmation) when is_map(confirmation) do
    script_details(confirmation) ++ result_details(confirmation)
  end

  @doc "Return script/result lines from a runtime action map."
  @spec action_lines(map() | nil) :: [String.t()]
  def action_lines(action) when is_map(action) do
    if action_name(action) == "run_skill_script" do
      script_detail_lines(field(action, "script") || %{}) ++
        result_detail_lines(field(action, "result") || %{})
    else
      []
    end
  end

  def action_lines(_action), do: []

  defp script_detail_lines(summary) when is_map(summary) do
    [
      {"Skill", field(summary, "skill_name")},
      {"Script", field(summary, "script_path")},
      {"Digest", field(summary, "script_sha256")},
      {"Cwd", field(summary, "resolved_cwd") || field(summary, "cwd")},
      {"Sandbox", sandbox_text(summary)},
      {"Timeout", ms_text(field(summary, "timeout_ms"))},
      {"Output cap", bytes_text(field(summary, "max_output_bytes"))},
      {"Env", env_text(field(summary, "env_keys"))},
      {"Denial", denial_text(field(summary, "denial_reason"))}
    ]
    |> reject_blank_values()
    |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)
  end

  defp script_detail_lines(_summary), do: []

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

  defp sandbox_text(summary) do
    case field(summary, "sandbox_level") do
      nil -> nil
      level -> "level #{level}"
    end
  end

  defp ms_text(nil), do: nil
  defp ms_text(value), do: "#{value}ms"

  defp bytes_text(nil), do: nil
  defp bytes_text(value), do: "#{value} bytes"

  defp env_text(values) when is_list(values), do: Enum.join(values, ", ")
  defp env_text(_values), do: nil

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

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp action_name(action), do: field(action, "name")
end
