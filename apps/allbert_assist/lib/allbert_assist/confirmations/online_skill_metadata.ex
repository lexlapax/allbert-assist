defmodule AllbertAssist.Confirmations.OnlineSkillMetadata do
  @moduledoc """
  Operator-facing online-skill metadata extracted from confirmation records.
  """

  @online_actions ~w[search_online_skills show_online_skill audit_online_skill import_online_skill]

  @spec online_confirmation?(map()) :: boolean()
  def online_confirmation?(confirmation) when is_map(confirmation) do
    get_in(confirmation, ["target_action", "name"]) in @online_actions
  end

  @spec lines(map()) :: [String.t()]
  def lines(confirmation) when is_map(confirmation) do
    if online_confirmation?(confirmation) do
      request_lines(params_summary(confirmation)) ++ result_lines(target_result(confirmation))
    else
      []
    end
  end

  def lines(_confirmation), do: []

  defp request_lines(summary) when is_map(summary) do
    source = field(summary, "source") || %{}

    [
      {"Source", field(source, "id")},
      {"Query", field(summary, "query")},
      {"Skill id", field(summary, "id")},
      {"Base URL", field(source, "base_url")},
      {"API URL", field(source, "api_url")}
    ]
    |> reject_blank_values()
    |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)
  end

  defp request_lines(_summary), do: []

  defp result_lines(result) when is_map(result) and result != %{} do
    [
      {"Result status", field(result, "status")},
      {"Results", result_count(result)},
      {"Imported target", field(result, "target_root")},
      {"Manifest", field(result, "manifest_path")},
      {"Audit", audit_status(result)}
    ]
    |> reject_blank_values()
    |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)
  end

  defp result_lines(_result), do: []

  defp params_summary(confirmation), do: Map.get(confirmation, "params_summary", %{}) || %{}

  defp target_result(confirmation) do
    get_in(confirmation, ["operator_resolution", "target_result"]) || %{}
  end

  defp result_count(result) do
    case field(result, "results") do
      values when is_list(values) -> length(values)
      _other -> nil
    end
  end

  defp audit_status(result) do
    result
    |> field("audit")
    |> case do
      audit when is_map(audit) -> field(audit, "status")
      _other -> field(result, "status")
    end
  end

  defp reject_blank_values(items) do
    Enum.reject(items, fn {_label, value} -> value in [nil, ""] end)
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp field(_map, _key), do: nil
end
