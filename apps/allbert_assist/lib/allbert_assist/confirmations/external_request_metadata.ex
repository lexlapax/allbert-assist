defmodule AllbertAssist.Confirmations.ExternalRequestMetadata do
  @moduledoc """
  Operator-facing external request metadata extracted from confirmations/actions.

  This module formats already-redacted v0.10 request/result summaries. It does
  not own network policy, approval, storage, or execution.
  """

  alias AllbertAssist.Maps

  def external_confirmation?(confirmation) when is_map(confirmation) do
    get_in(confirmation, ["target_action", "name"]) == "external_network_request"
  end

  def external_confirmation?(_confirmation), do: false

  def request_details(confirmation) when is_map(confirmation) do
    if external_confirmation?(confirmation) do
      request_detail_lines(params_summary(confirmation))
    else
      []
    end
  end

  def request_details(_confirmation), do: []

  def result_details(confirmation) when is_map(confirmation) do
    result = target_result(confirmation)

    if external_confirmation?(confirmation) and result != %{} do
      result_detail_lines(result, target_status(confirmation))
    else
      []
    end
  end

  def result_details(_confirmation), do: []

  def lines(confirmation) when is_map(confirmation) do
    request_details(confirmation) ++ result_details(confirmation)
  end

  def lines(_confirmation), do: []

  def action_lines(action) when is_map(action) do
    if action_name(action) == "external_network_request" do
      request_detail_lines(field(action, "request") || %{}) ++
        result_detail_lines(field(action, "result") || %{})
    else
      []
    end
  end

  def action_lines(_action), do: []

  defp request_detail_lines(summary) when is_map(summary) do
    [
      {"Method", field(summary, "method")},
      {"URL", field(summary, "url")},
      {"Profile", field(summary, "profile")},
      {"Host", field(summary, "host")},
      {"Path", field(summary, "path")},
      {"Timeout", ms_text(field(summary, "timeout_ms"))},
      {"Response cap", bytes_text(field(summary, "max_response_bytes"))},
      {"Redirects", redirect_text(summary)},
      {"Retry", field(summary, "retry_policy")},
      {"Denial", denial_text(field(summary, "denial_reason"))}
    ]
    |> reject_blank_values()
    |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)
  end

  defp request_detail_lines(_summary), do: []

  defp result_detail_lines(result, fallback_status \\ nil)

  defp result_detail_lines(result, fallback_status) when is_map(result) do
    [
      {"Result", field(result, "status") || fallback_status},
      {"HTTP status", field(result, "http_status")},
      {"Duration", ms_text(field(result, "duration_ms"))},
      {"Truncated", field(result, "truncated?")},
      {"Body bytes", field(result, "response_body_bytes")},
      {"Body preview", body_preview(result)},
      {"Transport error", field(result, "transport_error")}
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

  defp redirect_text(summary) do
    case field(summary, "allow_redirects?") do
      nil -> nil
      false -> "disabled"
      "false" -> "disabled"
      true -> "enabled max #{field(summary, "max_redirects") || 0}"
      "true" -> "enabled max #{field(summary, "max_redirects") || 0}"
      value -> inspect(value)
    end
  end

  defp ms_text(nil), do: nil
  defp ms_text(value), do: "#{value}ms"

  defp bytes_text(nil), do: nil
  defp bytes_text(value), do: "#{value} bytes"

  defp denial_text(value) when value in [nil, "nil", ""], do: nil
  defp denial_text(value), do: inspect(value)

  defp body_preview(result) do
    result
    |> field("body_preview")
    |> case do
      value when value in [nil, ""] -> nil
      value -> String.trim_trailing(to_string(value))
    end
  end

  defp reject_blank_values(items) do
    Enum.reject(items, fn {_label, value} -> value in [nil, ""] end)
  end

  defp field(map, key) when is_map(map), do: Maps.field_truthy(map, key)

  defp action_name(action), do: field(action, "name")
end
