defmodule AllbertAssist.Confirmations.ShellCommandMetadata do
  @moduledoc """
  Operator-facing shell command metadata extracted from confirmation records.

  This is a formatting helper only. Policy decisions, execution, and approval
  semantics stay behind registered actions.
  """

  @doc "Return true when a confirmation targets v0.08 shell execution."
  @spec shell_confirmation?(map()) :: boolean()
  def shell_confirmation?(confirmation) when is_map(confirmation) do
    get_in(confirmation, ["target_action", "name"]) == "run_shell_command"
  end

  @doc "Return compact command details for CLI and LiveView surfaces."
  @spec command_details(map()) :: [String.t()]
  def command_details(confirmation) when is_map(confirmation) do
    if shell_confirmation?(confirmation) do
      summary = params_summary(confirmation)

      [
        {"Command", command_line(summary)},
        {"Cwd", field(summary, "resolved_cwd") || field(summary, "cwd")},
        {"Sandbox", sandbox_text(summary)},
        {"Timeout", ms_text(field(summary, "timeout_ms"))},
        {"Output cap", bytes_text(field(summary, "max_output_bytes"))},
        {"Denial", denial_text(field(summary, "denial_reason"))}
      ]
      |> reject_blank_values()
      |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)
    else
      []
    end
  end

  @doc "Return compact target result details for resolved shell confirmations."
  @spec result_details(map()) :: [String.t()]
  def result_details(confirmation) when is_map(confirmation) do
    result = target_result(confirmation)

    if shell_confirmation?(confirmation) and result != %{} do
      [
        {"Result", field(result, "status") || target_status(confirmation)},
        {"Exit", field(result, "exit_status")},
        {"Timed out", field(result, "timed_out?")},
        {"Truncated", field(result, "truncated?")},
        {"Output bytes", field(result, "output_bytes")},
        {"Output preview", output_preview(result)}
      ]
      |> reject_blank_values()
      |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)
    else
      []
    end
  end

  @doc "Return all available command/result lines for a shell confirmation."
  @spec lines(map()) :: [String.t()]
  def lines(confirmation) when is_map(confirmation) do
    command_details(confirmation) ++ result_details(confirmation)
  end

  defp params_summary(confirmation), do: Map.get(confirmation, "params_summary", %{}) || %{}

  defp target_result(confirmation) do
    get_in(confirmation, ["operator_resolution", "target_result"]) || %{}
  end

  defp target_status(confirmation) do
    get_in(confirmation, ["operator_resolution", "target_status"])
  end

  defp command_line(summary) do
    executable = field(summary, "executable")
    args = field(summary, "args") || []

    if blank?(executable) do
      nil
    else
      ([executable] ++ normalize_args(args))
      |> Enum.join(" ")
    end
  end

  defp normalize_args(args) when is_list(args), do: Enum.map(args, &to_string/1)
  defp normalize_args(_args), do: []

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

  defp field(_map, _key), do: nil
end
