defmodule AllbertAssist.Objectives.ObservationSummary do
  @moduledoc """
  Pure normalization boundary for durable Objective observation summaries.
  """

  alias AllbertAssist.Runtime.Redactor

  @max_chars 2_000

  @doc "Redact one observation at the signal boundary and return durable text."
  @spec normalize(term()) :: String.t()
  def normalize(summary) do
    summary = summary |> Redactor.redact(:signals) |> to_string()

    if String.length(summary) > @max_chars do
      String.slice(summary, 0, @max_chars - 1) <> "…"
    else
      summary
    end
  end
end
