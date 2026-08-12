defmodule StockSage.Reflections do
  @moduledoc """
  Deterministic StockSage outcome reflections.

  Reflections are StockSage-local memory rows. They are not Allbert markdown
  memory and are not promoted unless a later explicit sync action does so.
  """

  alias StockSage.{Analyses, Memory}
  alias StockSage.Domain.{Analysis, Outcome}

  @legacy_source "stocksage_reflection"
  @default_max_chars 1_200
  @max_chars 4_000

  @type result :: %{
          entry_id: String.t(),
          analysis_id: String.t() | nil,
          outcome_id: String.t(),
          symbol: String.t(),
          label: String.t(),
          content: String.t(),
          promoted_to_allbert_memory: boolean()
        }

  @spec generate(term(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def generate(user_id, outcome_id, opts \\ [])

  def generate(user_id, outcome_id, opts) when is_binary(outcome_id) do
    with {:ok, outcome} <- Analyses.get_outcome(user_id, outcome_id),
         :ok <- require_resolved(outcome),
         content <- reflection_content(outcome, opts),
         {:ok, entry} <- upsert_reflection(user_id, outcome, content, opts) do
      {:ok,
       %{
         entry_id: entry.id,
         analysis_id: entry.analysis_id,
         outcome_id: outcome.id,
         symbol: outcome.symbol,
         label: outcome.label,
         content: entry.content,
         promoted_to_allbert_memory: entry.promoted_to_allbert_memory
       }}
    end
  end

  def generate(_user_id, _outcome_id, _opts), do: {:error, :missing_outcome_id}

  defp require_resolved(%Outcome{label: "pending"}), do: {:error, :unresolved_outcome}
  defp require_resolved(%Outcome{label: nil}), do: {:error, :unresolved_outcome}
  defp require_resolved(%Outcome{}), do: :ok

  defp reflection_content(outcome, opts) do
    max_chars =
      opts
      |> Keyword.get(:max_chars, @default_max_chars)
      |> normalize_max_chars()

    outcome
    |> content_lines()
    |> Enum.join("\n")
    |> redact_text()
    |> String.slice(0, max_chars)
  end

  defp content_lines(%Outcome{} = outcome) do
    analysis = outcome.analysis
    rating = analysis_recommendation(analysis)
    horizon = outcome.horizon_days || "open"
    return_pct = format_return(outcome.return_pct)

    [
      "Observed outcome: #{outcome.symbol} resolved as #{outcome.label} over #{horizon} days with #{return_pct}.",
      "Original rating: #{rating}.",
      "Analysis source: #{analysis_source(analysis)}.",
      lesson_line(outcome, rating),
      "Boundary: this reflection is StockSage-local advisory context; it is not durable Allbert markdown memory until explicit lesson sync."
    ]
  end

  defp lesson_line(%Outcome{label: "win"}, rating) do
    "Lesson: preserve the evidence pattern that supported #{rating} when similar setups recur."
  end

  defp lesson_line(%Outcome{label: "loss"}, rating) do
    "Lesson: review the evidence pattern behind #{rating} before reusing it in similar setups."
  end

  defp lesson_line(%Outcome{label: "neutral"}, rating) do
    "Lesson: treat #{rating} as directionally inconclusive for this holding period."
  end

  defp lesson_line(%Outcome{label: "unknown"}, _rating) do
    "Lesson: outcome evidence is incomplete; avoid promoting this as a reusable rule."
  end

  defp lesson_line(_outcome, _rating) do
    "Lesson: use this as context only after an operator reviews the observed result."
  end

  defp upsert_reflection(user_id, outcome, content, opts) do
    Memory.upsert_entry(%{
      user_id: user_id,
      analysis_id: outcome.analysis_id,
      kind: "reflection",
      content: content,
      tags: %{
        "symbol" => outcome.symbol,
        "label" => outcome.label,
        "source" => "outcome_resolution"
      },
      confidence: Decimal.new("0.70"),
      source: "analysis",
      legacy_source: @legacy_source,
      legacy_id: outcome.id,
      metadata: %{
        "outcome_id" => outcome.id,
        "analysis_id" => outcome.analysis_id,
        "objective_id" => analysis_field(outcome.analysis, :objective_id),
        "step_id" => analysis_field(outcome.analysis, :step_id),
        "generated_at" => now_iso8601(),
        "generator" => "stocksage_reflection_deterministic",
        "max_chars" => normalize_max_chars(Keyword.get(opts, :max_chars, @default_max_chars))
      }
    })
  end

  defp analysis_recommendation(%Analysis{recommendation: recommendation})
       when is_binary(recommendation) do
    case String.trim(recommendation) do
      "" -> "unrated"
      rating -> rating
    end
  end

  defp analysis_recommendation(_analysis), do: "unrated"

  defp analysis_source(%Analysis{source: source, engine: engine}) do
    [source, engine]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("/")
    |> case do
      "" -> "unknown"
      value -> value
    end
  end

  defp analysis_source(_analysis), do: "unknown"

  defp analysis_field(%Analysis{} = analysis, field), do: Map.get(analysis, field)
  defp analysis_field(_analysis, _field), do: nil

  defp format_return(%Decimal{} = value), do: "#{Decimal.to_string(value, :normal)}% return"
  defp format_return(nil), do: "no recorded return"
  defp format_return(value), do: "#{value}% return"

  defp normalize_max_chars(value) when is_integer(value) do
    value
    |> max(200)
    |> min(@max_chars)
  end

  defp normalize_max_chars(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_max_chars(parsed)
      _ -> @default_max_chars
    end
  end

  defp normalize_max_chars(_value), do: @default_max_chars

  defp redact_text(text) do
    String.replace(text, ~r/secret:\/\/[^\s]+/, "[SECRET_REF]")
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
