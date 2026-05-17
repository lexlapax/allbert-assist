defmodule AllbertAssist.Confirmations.ObjectiveContext do
  @moduledoc """
  Bounded objective rendering context for confirmation surfaces.

  Confirmation records are YAML-backed and may outlive the objective state
  snapshot captured when the confirmation was created. This helper keeps CLI,
  LiveView, Telegram, and email renderers on the same stale-warning rule.
  """

  alias AllbertAssist.Objectives
  alias AllbertAssist.Security.Redactor

  @max_title 200

  @spec info(map() | nil) :: map() | nil
  def info(record_or_handoff)

  def info(nil), do: nil

  def info(record_or_handoff) when is_map(record_or_handoff) do
    objective_id = field(record_or_handoff, :objective_id)
    params_summary = params_summary(record_or_handoff)
    objective_id = objective_id || field(params_summary, :objective_id)

    if blank?(objective_id) do
      nil
    else
      snapshot_title = field(params_summary, :objective_title)
      snapshot_status = field(params_summary, :objective_status)

      live =
        case Objectives.get_objective(objective_id) do
          {:ok, objective} -> objective
          {:error, _reason} -> nil
        end

      %{
        objective_id: objective_id,
        step_id: field(record_or_handoff, :step_id) || field(params_summary, :step_id),
        title: bounded((live && live.title) || snapshot_title || objective_id, @max_title),
        status: (live && live.status) || snapshot_status,
        snapshot_status: snapshot_status,
        stale?: stale?(snapshot_status, live),
        stale_note: stale_note(snapshot_status, live)
      }
      |> Redactor.redact()
    end
  end

  @spec lines(map() | nil) :: [String.t()]
  def lines(record_or_handoff) do
    case info(record_or_handoff) do
      nil ->
        []

      info ->
        [
          info[:stale_note],
          "Objective: #{info.objective_id}",
          "  Title: #{info.title}",
          "  Status: #{status_text(info.status)}",
          step_line(info[:step_id])
        ]
        |> Enum.reject(&blank?/1)
    end
  end

  defp params_summary(record_or_handoff) do
    field(record_or_handoff, :params_summary) ||
      record_or_handoff
      |> field(:target_action, %{})
      |> field(:params_summary, %{})
  end

  defp stale?(nil, _live), do: false
  defp stale?(_snapshot_status, nil), do: false
  defp stale?(snapshot_status, live), do: status_text(live.status) != status_text(snapshot_status)

  defp stale_note(nil, _live), do: nil
  defp stale_note(_snapshot_status, nil), do: nil

  defp stale_note(snapshot_status, live) do
    if stale?(snapshot_status, live) do
      "Note: objective is now #{status_text(live.status)} (was #{status_text(snapshot_status)} at confirmation creation)"
    end
  end

  defp step_line(nil), do: nil
  defp step_line(""), do: nil
  defp step_line(step_id), do: "Step: #{step_id}"

  defp status_text(nil), do: "unknown"
  defp status_text(status), do: ":" <> (status |> to_string() |> String.trim_leading(":"))

  defp bounded(value, max) do
    value = to_string(value)

    if String.length(value) > max do
      String.slice(value, 0, max) <> "..."
    else
      value
    end
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
