defmodule AllbertAssist.Intent.Router.InputGuard do
  @moduledoc """
  Small deterministic guard for utterances that must never enter action routing.

  This is not an authority grant and does not execute anything. It only maps
  command-shaped operator/internal-action phrasing to `:none` before the
  prefilter/model can accidentally select a public sibling action.
  """

  alias AllbertAssist.Intent.Router.Outcome

  @none "__none__"

  @spec guarded_outcome(String.t()) :: {:ok, Outcome.t()} | :continue
  def guarded_outcome(query) do
    case guard_reason(query) do
      nil -> :continue
      reason -> {:ok, Outcome.none(%{note: reason})}
    end
  end

  @spec sentinel_selection(String.t()) :: {:ok, map()} | :continue
  def sentinel_selection(query) do
    case guard_reason(query) do
      nil -> :continue
      reason -> {:ok, %{selected: @none, confidence: 1.0, slots: %{}, reason: reason}}
    end
  end

  defp guard_reason(query) do
    cond do
      slash_command?(query) -> :slash_command
      operator_internal_action_request?(query) -> :operator_internal_action_request
      true -> nil
    end
  end

  defp slash_command?(query),
    do: query |> to_string() |> String.trim() |> String.starts_with?("/")

  defp operator_internal_action_request?(query) do
    raw =
      query
      |> to_string()
      |> String.downcase()
      |> String.trim()

    normalized =
      raw
      |> String.replace(~r/[^a-z0-9_]+/u, " ")
      |> String.trim()

    String.starts_with?(normalized, "operator inspect internal action ") or
      operator_run_action_name?(raw)
  end

  defp operator_run_action_name?(raw) do
    Regex.match?(~r/^operator\s+run\s+[a-z0-9_]+$/u, raw) and String.contains?(raw, "_")
  end
end
