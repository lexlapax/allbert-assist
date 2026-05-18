defmodule StockSage.Agents.CommitteeContext do
  @moduledoc """
  Builds deterministic advisory context for the final StockSage synthesizer.

  This module does not decide a rating. It turns prior specialist packets into
  an ordered committee ledger so the final LLM sees the same role structure
  every run: analyst packets, bull/bear debate, and risk committee stances.
  """

  @ratings ["Buy", "Overweight", "Hold", "Underweight", "Sell"]
  @cautious_ratings ["Underweight", "Sell"]
  @constructive_ratings ["Buy", "Overweight"]

  @spec ordered_reports(map()) :: [{String.t(), map()}]
  def ordered_reports(prior_reports) when is_map(prior_reports) do
    prior_reports
    |> Enum.map(fn {agent_id, report} -> {to_string(agent_id), report} end)
    |> Enum.sort_by(fn {agent_id, _report} ->
      role = role(agent_id)
      {order(role, round_index(agent_id)), agent_id}
    end)
  end

  def ordered_reports(_prior_reports), do: []

  @spec summary(map()) :: map()
  def summary(prior_reports) when is_map(prior_reports) do
    entries =
      prior_reports
      |> ordered_reports()
      |> Enum.map(fn {agent_id, report} -> entry(agent_id, report) end)
      |> Enum.sort_by(fn entry -> {entry.order, entry.agent_id} end)

    %{
      ordered_stances: Enum.map(entries, &Map.drop(&1, [:order])),
      rating_counts: rating_counts(entries),
      directional_balance: directional_balance(entries),
      risk_committee: risk_committee(entries),
      cautious_reports: cautious_reports(entries),
      decision_guidance:
        "Use this ledger only as advisory structure. Weigh evidence quality, " <>
          "risk objections, and unresolved data gaps before choosing the final rating."
    }
  end

  def summary(_prior_reports) do
    %{
      ordered_stances: [],
      rating_counts: %{},
      directional_balance: %{constructive: 0, neutral: 0, cautious: 0},
      risk_committee: [],
      cautious_reports: [],
      decision_guidance: "No prior committee packets were provided; avoid fabricating conviction."
    }
  end

  defp entry(agent_id, report) do
    role = role(agent_id)
    rating = rating(report)

    %{
      agent_id: agent_id,
      role: role,
      round_index: round_index(agent_id),
      rating: rating,
      confidence: field(report, :confidence),
      summary: bounded_text(field(report, :summary), 500),
      warnings: report |> field(:warnings, []) |> list_value() |> Enum.take(4),
      order: order(role, round_index(agent_id))
    }
    |> drop_nil_values()
  end

  defp rating(report) do
    [
      field(report, :final_trade_decision),
      field(report, :rating),
      field(report, :recommendation),
      field(report, :summary),
      field(report, :report)
    ]
    |> Enum.find_value(&normalize_rating/1)
  end

  defp normalize_rating(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    Enum.find(@ratings, fn rating ->
      downcased = String.downcase(rating)
      normalized == downcased or Regex.match?(~r/\b#{Regex.escape(downcased)}\b/, normalized)
    end)
  end

  defp normalize_rating(_value), do: nil

  defp rating_counts(entries) do
    entries
    |> Enum.map(&Map.get(&1, :rating))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp directional_balance(entries) do
    Enum.reduce(entries, %{constructive: 0, neutral: 0, cautious: 0}, fn entry, acc ->
      case Map.get(entry, :rating) do
        rating when rating in @constructive_ratings -> Map.update!(acc, :constructive, &(&1 + 1))
        "Hold" -> Map.update!(acc, :neutral, &(&1 + 1))
        rating when rating in @cautious_ratings -> Map.update!(acc, :cautious, &(&1 + 1))
        _other -> acc
      end
    end)
  end

  defp risk_committee(entries) do
    entries
    |> Enum.filter(&(Map.get(&1, :role) in [:risk_aggressive, :risk_conservative, :risk_neutral]))
    |> Enum.map(&Map.drop(&1, [:order]))
  end

  defp cautious_reports(entries) do
    entries
    |> Enum.filter(fn entry ->
      Map.get(entry, :rating) in @cautious_ratings or
        Map.get(entry, :role) in [:bear_thesis, :risk_conservative]
    end)
    |> Enum.map(fn entry ->
      entry
      |> Map.take([:agent_id, :role, :round_index, :rating, :summary, :warnings])
      |> drop_nil_values()
    end)
  end

  defp role(agent_id) do
    agent_id
    |> String.replace(~r/\.round_\d+$/, "")
    |> case do
      "stocksage.market_context" -> :market_context
      "stocksage.news_sentiment" -> :news_sentiment
      "stocksage.fundamentals" -> :fundamentals
      "stocksage.bull_thesis" -> :bull_thesis
      "stocksage.bear_thesis" -> :bear_thesis
      "stocksage.risk_aggressive" -> :risk_aggressive
      "stocksage.risk_conservative" -> :risk_conservative
      "stocksage.risk_neutral" -> :risk_neutral
      "stocksage.research_manager" -> :research_manager
      "stocksage.trader_plan" -> :trader_plan
      "stocksage.decision_synthesizer" -> :decision_synthesizer
      _other -> :unknown
    end
  end

  defp round_index(agent_id) do
    case Regex.run(~r/\.round_(\d+)$/, agent_id) do
      [_match, value] -> String.to_integer(value)
      _other -> nil
    end
  end

  defp order(:market_context, _round), do: {0, 0}
  defp order(:news_sentiment, _round), do: {1, 0}
  defp order(:fundamentals, _round), do: {2, 0}
  defp order(:bull_thesis, round), do: {3, round || 0}
  defp order(:bear_thesis, round), do: {4, round || 0}
  defp order(:research_manager, round), do: {5, round || 0}
  defp order(:trader_plan, round), do: {6, round || 0}
  defp order(:risk_aggressive, round), do: {7, round || 0}
  defp order(:risk_conservative, round), do: {8, round || 0}
  defp order(:risk_neutral, round), do: {9, round || 0}
  defp order(_role, round), do: {99, round || 0}

  defp bounded_text(nil, _limit), do: nil

  defp bounded_text(value, limit) do
    text = if is_binary(value), do: value, else: inspect(value, limit: 12, printable_limit: limit)

    if byte_size(text) > limit do
      binary_part(text, 0, limit)
    else
      text
    end
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp field(_map, _key, default), do: default

  defp list_value(value) when is_list(value), do: value
  defp list_value(nil), do: []
  defp list_value(value), do: [inspect(value, limit: 6, printable_limit: 240)]

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
