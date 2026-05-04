defmodule AllbertAssist.Confirmations.OnlineSkillMetadata do
  @moduledoc """
  Operator-facing online-skill metadata extracted from confirmation records.
  """

  @online_actions ~w[
    search_online_skills
    show_online_skill
    audit_online_skill
    import_online_skill
    import_remote_skill
    import_local_skill
  ]

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

  @doc "Return online skill request/result lines from a runtime action map."
  @spec action_lines(map() | nil) :: [String.t()]
  def action_lines(action) when is_map(action) do
    if action_name(action) in @online_actions do
      request_lines(action_online_summary(action)) ++ result_lines(action_online_result(action))
    else
      []
    end
  end

  def action_lines(_action), do: []

  defp request_lines(summary) when is_map(summary) do
    source = field(summary, "source") || %{}

    [
      {"Source", field(source, "id")},
      {"Operation", field(summary, "operation")},
      {"Query", field(summary, "query")},
      {"URL", field(summary, "url")},
      {"Path", field(summary, "path")},
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
      {"Failure", reason_text(field(result, "failure_reason") || field(result, "denial_reason"))},
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

  defp reason_text(nil), do: nil
  defp reason_text(""), do: nil

  defp reason_text(%{"code" => code, "detail" => detail}) do
    "#{code}: #{detail}"
  end

  defp reason_text(%{code: code, detail: detail}) do
    "#{code}: #{detail}"
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp reject_blank_values(items) do
    Enum.reject(items, fn {_label, value} -> value in [nil, ""] end)
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp field(_map, _key), do: nil

  defp action_online_summary(action) do
    field(action, "online_skill") ||
      field(action, "online_skill_search") ||
      field(action, "online_skill_detail") ||
      field(action, "online_skill_audit") ||
      field(action, "online_skill_import") ||
      field(action, "online_skill_import_request") ||
      field(action, "skill_import") ||
      field(action, "skill_import_request") ||
      %{}
  end

  defp action_online_result(action) do
    field(action, "online_skill_search") ||
      field(action, "online_skill_detail") ||
      field(action, "online_skill_audit") ||
      field(action, "online_skill_import") ||
      field(action, "skill_import") ||
      field(action, "result") ||
      %{}
  end

  defp action_name(action), do: field(action, "name")
end
