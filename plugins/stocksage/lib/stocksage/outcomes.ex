defmodule StockSage.Outcomes do
  @moduledoc """
  Deterministic StockSage outcome resolution.

  This context compares already-recorded starting prices with explicit
  observed prices or fixture prices supplied by the caller. It does not fetch
  market data and does not write Allbert markdown memory.
  """

  import Ecto.Query

  alias AllbertAssist.Repo
  alias StockSage.Analyses
  alias StockSage.Domain
  alias StockSage.Domain.{Analysis, Outcome}

  @default_limit 50
  @max_limit 100
  @default_neutral_threshold Decimal.new("0.5")
  @zero Decimal.new(0)

  @type resolution_summary :: %{
          user_id: String.t(),
          as_of: Date.t(),
          attempted: non_neg_integer(),
          resolved: non_neg_integer(),
          pending: non_neg_integer(),
          skipped: non_neg_integer(),
          outcomes: [map()]
        }

  @doc """
  Resolve due pending outcomes for a user.

  `prices` is an optional map keyed by symbol (`"AAPL"` or `:AAPL`) with
  observed end prices. Existing `end_price` values on the outcome are used
  when no fixture price is provided.
  """
  @spec resolve_due(term(), keyword()) :: resolution_summary()
  def resolve_due(user_id, opts \\ []) do
    normalized_user_id = Domain.normalize_user_id(user_id)
    as_of = normalize_date(Keyword.get(opts, :as_of), Date.utc_today())
    limit = Domain.normalize_limit(Keyword.get(opts, :limit), @default_limit, @max_limit)
    force? = truthy?(Keyword.get(opts, :force, false))
    prices = normalize_prices(Keyword.get(opts, :prices, %{}))

    threshold =
      normalize_decimal(Keyword.get(opts, :neutral_return_threshold_pct)) ||
        @default_neutral_threshold

    outcomes =
      normalized_user_id
      |> candidate_outcomes(force?)
      |> limit(^limit)
      |> Repo.all()
      |> Repo.preload(:analysis)

    outcome_results =
      Enum.map(outcomes, fn outcome ->
        resolve_outcome(outcome, as_of, prices, threshold, force?)
      end)

    %{
      user_id: normalized_user_id,
      as_of: as_of,
      attempted: length(outcome_results),
      resolved: count_status(outcome_results, :resolved),
      pending: count_status(outcome_results, :pending),
      skipped: count_status(outcome_results, :skipped),
      outcomes: outcome_results
    }
  end

  defp candidate_outcomes(user_id, true) do
    Outcome
    |> where([outcome], outcome.user_id == ^user_id)
    |> order_by([outcome], asc: outcome.observed_on, asc: outcome.updated_at)
  end

  defp candidate_outcomes(user_id, false) do
    Outcome
    |> where([outcome], outcome.user_id == ^user_id and outcome.label == "pending")
    |> order_by([outcome], asc: outcome.observed_on, asc: outcome.updated_at)
  end

  defp resolve_outcome(outcome, as_of, prices, threshold, force?) do
    due_on = due_on(outcome)

    cond do
      is_nil(due_on) ->
        mark_pending(outcome, as_of, :missing_due_date)

      Date.compare(due_on, as_of) == :gt and not force? ->
        outcome_summary(outcome, :skipped, :not_due)

      true ->
        do_resolve_outcome(outcome, as_of, due_on, prices, threshold)
    end
  end

  defp do_resolve_outcome(outcome, as_of, due_on, prices, threshold) do
    start_price = normalize_decimal(outcome.start_price)
    end_price = price_for(outcome, prices) || normalize_decimal(outcome.end_price)

    cond do
      is_nil(start_price) ->
        mark_pending(outcome, as_of, :missing_start_price)

      Decimal.compare(start_price, @zero) in [:eq, :lt] ->
        mark_pending(outcome, as_of, :invalid_start_price)

      is_nil(end_price) ->
        mark_pending(outcome, as_of, :missing_end_price)

      true ->
        return_pct = return_pct(start_price, end_price)
        label = classify(outcome.analysis, return_pct, threshold)

        attrs = %{
          observed_on: outcome.observed_on || due_on,
          end_price: end_price,
          return_pct: return_pct,
          label: label,
          metadata:
            outcome
            |> metadata()
            |> Map.put("resolution", %{
              "status" => "resolved",
              "resolved_at" => now_iso8601(),
              "as_of" => Date.to_iso8601(as_of),
              "due_on" => Date.to_iso8601(due_on),
              "source" => "stocksage_outcome_resolver",
              "recommendation" => analysis_recommendation(outcome.analysis),
              "objective_id" => analysis_field(outcome.analysis, :objective_id),
              "step_id" => analysis_field(outcome.analysis, :step_id),
              "neutral_return_threshold_pct" => Decimal.to_string(threshold, :normal)
            })
        }

        case Analyses.update_outcome(outcome, attrs) do
          {:ok, updated} -> outcome_summary(updated, :resolved, :resolved)
          {:error, changeset} -> invalid_summary(outcome, changeset)
        end
    end
  end

  defp mark_pending(outcome, as_of, reason) do
    attrs = %{
      metadata:
        outcome
        |> metadata()
        |> Map.put("resolution", %{
          "status" => "pending",
          "reason" => Atom.to_string(reason),
          "attempted_at" => now_iso8601(),
          "as_of" => Date.to_iso8601(as_of),
          "source" => "stocksage_outcome_resolver"
        })
    }

    case Analyses.update_outcome(outcome, attrs) do
      {:ok, updated} -> outcome_summary(updated, :pending, reason)
      {:error, changeset} -> invalid_summary(outcome, changeset)
    end
  end

  defp outcome_summary(outcome, status, reason) do
    %{
      id: outcome.id,
      analysis_id: outcome.analysis_id,
      symbol: outcome.symbol,
      status: status,
      reason: reason,
      label: outcome.label,
      horizon_days: outcome.horizon_days,
      observed_on: outcome.observed_on,
      start_price: outcome.start_price,
      end_price: outcome.end_price,
      return_pct: outcome.return_pct,
      objective_id: analysis_field(outcome.analysis, :objective_id),
      step_id: analysis_field(outcome.analysis, :step_id)
    }
  end

  defp invalid_summary(outcome, changeset) do
    %{
      id: outcome.id,
      analysis_id: outcome.analysis_id,
      symbol: outcome.symbol,
      status: :pending,
      reason: :invalid_update,
      label: outcome.label,
      errors: errors_on(changeset)
    }
  end

  defp due_on(%Outcome{observed_on: %Date{} = date}), do: date

  defp due_on(%Outcome{horizon_days: days, analysis: %Analysis{analysis_date: %Date{} = date}})
       when is_integer(days) do
    Date.add(date, days)
  end

  defp due_on(_outcome), do: nil

  defp price_for(%Outcome{symbol: symbol, observed_on: observed_on}, prices) do
    normalized_symbol = Domain.normalize_symbol(symbol)

    [
      {normalized_symbol, observed_on},
      {normalized_symbol, nil},
      {String.downcase(normalized_symbol || ""), observed_on},
      {String.downcase(normalized_symbol || ""), nil}
    ]
    |> Enum.find_value(fn key -> Map.get(prices, key) end)
  end

  defp return_pct(start_price, end_price) do
    end_price
    |> Decimal.sub(start_price)
    |> Decimal.div(start_price)
    |> Decimal.mult(Decimal.new(100))
    |> Decimal.round(4)
  end

  defp classify(analysis, return_pct, threshold) do
    direction = analysis |> analysis_recommendation() |> recommendation_direction()
    abs_return = Decimal.abs(return_pct)

    if Decimal.compare(abs_return, threshold) in [:lt, :eq] do
      "neutral"
    else
      positive? = Decimal.compare(return_pct, @zero) == :gt

      case {direction, positive?} do
        {:bullish, true} -> "win"
        {:bullish, false} -> "loss"
        {:bearish, false} -> "win"
        {:bearish, true} -> "loss"
        _other -> "unknown"
      end
    end
  end

  defp recommendation_direction(nil), do: :unknown

  defp recommendation_direction(recommendation) do
    normalized =
      recommendation
      |> to_string()
      |> String.downcase()

    cond do
      Regex.match?(~r/\b(buy|bull|long|outperform|overweight|accumulate)\b/, normalized) ->
        :bullish

      Regex.match?(~r/\b(sell|bear|short|underperform|underweight|reduce)\b/, normalized) ->
        :bearish

      Regex.match?(~r/\b(hold|neutral|market perform)\b/, normalized) ->
        :neutral

      true ->
        :unknown
    end
  end

  defp normalize_prices(prices) when is_map(prices) do
    Enum.reduce(prices, %{}, fn {raw_key, raw_value}, acc ->
      value = normalize_decimal(raw_value)

      if is_nil(value) do
        acc
      else
        key =
          case raw_key do
            {symbol, %Date{} = date} ->
              {Domain.normalize_symbol(symbol), date}

            {symbol, date} when is_binary(date) ->
              {Domain.normalize_symbol(symbol), normalize_date(date)}

            symbol ->
              {Domain.normalize_symbol(symbol), nil}
          end

        Map.put(acc, key, value)
      end
    end)
  end

  defp normalize_prices(_prices), do: %{}

  defp normalize_date(value, default \\ nil)

  defp normalize_date(nil, default), do: default
  defp normalize_date(%Date{} = date, _default), do: date

  defp normalize_date(value, default) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      {:error, _reason} -> default
    end
  end

  defp normalize_date(_value, default), do: default

  defp normalize_decimal(nil), do: nil
  defp normalize_decimal(%Decimal{} = decimal), do: decimal
  defp normalize_decimal(value) when is_integer(value), do: Decimal.new(value)

  defp normalize_decimal(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 8)
    |> Decimal.new()
  end

  defp normalize_decimal(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> Decimal.new(trimmed)
    end
  rescue
    Decimal.Error -> nil
  end

  defp normalize_decimal(_value), do: nil

  defp analysis_recommendation(%Analysis{recommendation: recommendation}), do: recommendation
  defp analysis_recommendation(_analysis), do: nil

  defp analysis_field(%Analysis{} = analysis, field), do: Map.get(analysis, field)
  defp analysis_field(_analysis, _field), do: nil

  defp metadata(%Outcome{metadata: metadata}) when is_map(metadata), do: metadata
  defp metadata(_outcome), do: %{}

  defp count_status(outcomes, status) do
    Enum.count(outcomes, &(Map.get(&1, :status) == status))
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
