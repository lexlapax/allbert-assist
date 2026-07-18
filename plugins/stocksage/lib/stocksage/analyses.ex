defmodule StockSage.Analyses do
  @moduledoc """
  StockSage analysis and outcome context.

  Every public read path is scoped by `user_id`; ids are not authority.
  """

  import Ecto.Query

  alias AllbertAssist.Repo
  alias StockSage.Domain
  alias StockSage.Domain.{Analysis, AnalysisDetail, Outcome}

  @default_limit 50
  @max_limit 100
  @resolved_labels ~w[win loss neutral unknown]

  @doc "Creates an analysis row."
  def create_analysis(attrs) when is_map(attrs) do
    %Analysis{}
    |> Analysis.changeset(prepare_attrs(attrs, "analysis"))
    |> Repo.insert()
  end

  @doc "Idempotently inserts or updates an analysis by legacy source/id when present."
  def upsert_analysis(attrs) when is_map(attrs) do
    with {:ok, user_id} <- required_string(attrs, :user_id),
         {:ok, legacy_source} <- required_string(attrs, :legacy_source),
         {:ok, legacy_id} <- required_string(attrs, :legacy_id) do
      case get_analysis_by_legacy(user_id, legacy_source, legacy_id) do
        nil -> create_analysis(attrs)
        analysis -> update_analysis(analysis, attrs)
      end
    else
      _ -> create_analysis(attrs)
    end
  end

  def update_analysis(%Analysis{} = analysis, attrs) when is_map(attrs) do
    sanitized =
      attrs
      |> Map.delete(:id)
      |> Map.delete("id")

    Analysis.changeset(analysis, sanitized)
    |> Repo.update()
  end

  def get_analysis(user_id, analysis_id) do
    normalized_user_id = Domain.normalize_user_id(user_id)

    Analysis
    |> where([analysis], analysis.user_id == ^normalized_user_id and analysis.id == ^analysis_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      analysis -> {:ok, analysis}
    end
  end

  def get_analysis_with_details(user_id, analysis_id, opts \\ []) do
    with {:ok, analysis} <- get_analysis(user_id, analysis_id) do
      detail_limit = Domain.normalize_limit(Keyword.get(opts, :detail_limit), 25, 100)
      outcome_limit = Domain.normalize_limit(Keyword.get(opts, :outcome_limit), 25, 100)

      {:ok,
       %{
         analysis
         | details: list_details_for_analysis(user_id, analysis.id, limit: detail_limit),
           outcomes: list_outcomes_for_analysis(user_id, analysis.id, limit: outcome_limit)
       }}
    end
  end

  def list_analyses(user_id, opts \\ []) do
    normalized_user_id = Domain.normalize_user_id(user_id)
    limit = Domain.normalize_limit(Keyword.get(opts, :limit), @default_limit, @max_limit)
    offset = Domain.normalize_offset(Keyword.get(opts, :offset))
    symbol = opts |> Keyword.get(:symbol) |> Domain.normalize_symbol()

    Analysis
    |> where([analysis], analysis.user_id == ^normalized_user_id)
    |> maybe_filter_symbol(symbol)
    |> order_by([analysis], desc: analysis.updated_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def create_detail(attrs) when is_map(attrs) do
    %AnalysisDetail{}
    |> AnalysisDetail.changeset(prepare_attrs(attrs, "detail"))
    |> Repo.insert()
  end

  def upsert_detail(attrs) when is_map(attrs) do
    with {:ok, analysis_id} <- required_string(attrs, :analysis_id),
         {:ok, legacy_source} <- required_string(attrs, :legacy_source),
         {:ok, legacy_id} <- required_string(attrs, :legacy_id) do
      case get_detail_by_legacy(analysis_id, legacy_source, legacy_id) do
        nil -> create_detail(attrs)
        detail -> update_detail(detail, attrs)
      end
    else
      _ -> create_detail(attrs)
    end
  end

  def update_detail(%AnalysisDetail{} = detail, attrs) when is_map(attrs) do
    sanitized =
      attrs
      |> Map.delete(:id)
      |> Map.delete("id")

    AnalysisDetail.changeset(detail, sanitized)
    |> Repo.update()
  end

  def list_details_for_analysis(user_id, analysis_id, opts \\ []) do
    normalized_user_id = Domain.normalize_user_id(user_id)
    limit = Domain.normalize_limit(Keyword.get(opts, :limit), 25, 100)

    AnalysisDetail
    |> where(
      [detail],
      detail.user_id == ^normalized_user_id and detail.analysis_id == ^analysis_id
    )
    |> order_by([detail], asc: detail.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def create_outcome(attrs) when is_map(attrs) do
    %Outcome{}
    |> Outcome.changeset(prepare_attrs(attrs, "outcome"))
    |> Repo.insert()
  end

  def upsert_outcome(attrs) when is_map(attrs) do
    with {:ok, user_id} <- required_string(attrs, :user_id),
         {:ok, legacy_source} <- required_string(attrs, :legacy_source),
         {:ok, legacy_id} <- required_string(attrs, :legacy_id) do
      case get_outcome_by_legacy(user_id, legacy_source, legacy_id) do
        nil -> create_outcome(attrs)
        outcome -> update_outcome(outcome, attrs)
      end
    else
      _ -> create_outcome(attrs)
    end
  end

  def update_outcome(%Outcome{} = outcome, attrs) when is_map(attrs) do
    sanitized =
      attrs
      |> Map.delete(:id)
      |> Map.delete("id")

    Outcome.changeset(outcome, sanitized)
    |> Repo.update()
  end

  def list_outcomes(user_id, opts \\ []) do
    normalized_user_id = Domain.normalize_user_id(user_id)
    limit = Domain.normalize_limit(Keyword.get(opts, :limit), @default_limit, @max_limit)
    symbol = opts |> Keyword.get(:symbol) |> Domain.normalize_symbol()

    Outcome
    |> where([outcome], outcome.user_id == ^normalized_user_id)
    |> maybe_filter_symbol(symbol)
    |> order_by([outcome], desc: outcome.observed_on, desc: outcome.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_outcomes_for_analysis(user_id, analysis_id, opts \\ []) do
    normalized_user_id = Domain.normalize_user_id(user_id)
    limit = Domain.normalize_limit(Keyword.get(opts, :limit), 25, 100)

    Outcome
    |> where(
      [outcome],
      outcome.user_id == ^normalized_user_id and outcome.analysis_id == ^analysis_id
    )
    |> order_by([outcome], desc: outcome.observed_on, desc: outcome.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_outcome(user_id, outcome_id) do
    normalized_user_id = Domain.normalize_user_id(user_id)

    Outcome
    |> where([outcome], outcome.user_id == ^normalized_user_id and outcome.id == ^outcome_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      outcome -> {:ok, Repo.preload(outcome, :analysis)}
    end
  end

  def summarize_trends(user_id, opts \\ []) do
    outcomes =
      user_id
      |> list_outcomes(opts)
      |> Repo.preload(:analysis)

    counts =
      Enum.reduce(outcomes, %{}, fn outcome, acc ->
        Map.update(acc, outcome.label, 1, &(&1 + 1))
      end)

    %{
      user_id: Domain.normalize_user_id(user_id),
      symbol: opts |> Keyword.get(:symbol) |> Domain.normalize_symbol(),
      returned: length(outcomes),
      counts: counts,
      accuracy: accuracy_summary(outcomes),
      rating_calibration: rating_calibration(outcomes),
      leaderboard: leaderboard(outcomes),
      outcomes: outcomes
    }
  end

  def get_analysis_by_legacy(user_id, legacy_source, legacy_id) do
    Analysis
    |> where(
      [analysis],
      analysis.user_id == ^Domain.normalize_user_id(user_id) and
        analysis.legacy_source == ^legacy_source and analysis.legacy_id == ^legacy_id
    )
    |> Repo.one()
  end

  def get_detail_by_legacy(analysis_id, legacy_source, legacy_id) do
    AnalysisDetail
    |> where(
      [detail],
      detail.analysis_id == ^analysis_id and detail.legacy_source == ^legacy_source and
        detail.legacy_id == ^legacy_id
    )
    |> Repo.one()
  end

  def get_outcome_by_legacy(user_id, legacy_source, legacy_id) do
    Outcome
    |> where(
      [outcome],
      outcome.user_id == ^Domain.normalize_user_id(user_id) and
        outcome.legacy_source == ^legacy_source and outcome.legacy_id == ^legacy_id
    )
    |> Repo.one()
  end

  defp prepare_attrs(attrs, prefix) do
    attrs
    |> atomize_known_keys()
    |> Domain.put_generated_id(prefix)
  end

  defp atomize_known_keys(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, String.to_existing_atom(key), value)
    end)
  rescue
    ArgumentError -> attrs
  end

  defp required_string(attrs, key) do
    value = AllbertAssist.Maps.field_truthy(attrs, key)

    if is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      :error
    end
  end

  defp maybe_filter_symbol(query, nil), do: query
  defp maybe_filter_symbol(query, ""), do: query

  defp maybe_filter_symbol(query, symbol) do
    where(query, [record], record.symbol == ^symbol)
  end

  defp accuracy_summary(outcomes) do
    resolved = resolved_outcomes(outcomes)
    wins = count_label(resolved, "win")
    losses = count_label(resolved, "loss")
    neutral = count_label(resolved, "neutral")
    unknown = count_label(resolved, "unknown")

    %{
      resolved: length(resolved),
      wins: wins,
      losses: losses,
      neutral: neutral,
      unknown: unknown,
      win_rate: percent(wins, length(resolved)),
      avg_return_pct: average_return(resolved),
      return_basis: :realized_return_no_benchmark
    }
  end

  defp rating_calibration(outcomes) do
    outcomes
    |> resolved_outcomes()
    |> Enum.group_by(&rating_for/1)
    |> Enum.map(fn {rating, rating_outcomes} ->
      wins = count_label(rating_outcomes, "win")
      losses = count_label(rating_outcomes, "loss")
      neutral = count_label(rating_outcomes, "neutral")
      unknown = count_label(rating_outcomes, "unknown")

      %{
        rating: rating,
        resolved: length(rating_outcomes),
        wins: wins,
        losses: losses,
        neutral: neutral,
        unknown: unknown,
        win_rate: percent(wins, length(rating_outcomes)),
        avg_return_pct: average_return(rating_outcomes)
      }
    end)
    |> Enum.sort_by(&{sort_rate(&1.win_rate), &1.resolved, &1.rating}, :desc)
  end

  defp leaderboard(outcomes) do
    outcomes
    |> resolved_outcomes()
    |> Enum.group_by(& &1.symbol)
    |> Enum.map(fn {symbol, symbol_outcomes} ->
      wins = count_label(symbol_outcomes, "win")
      losses = count_label(symbol_outcomes, "loss")
      neutral = count_label(symbol_outcomes, "neutral")
      unknown = count_label(symbol_outcomes, "unknown")

      %{
        symbol: symbol,
        resolved: length(symbol_outcomes),
        wins: wins,
        losses: losses,
        neutral: neutral,
        unknown: unknown,
        win_rate: percent(wins, length(symbol_outcomes)),
        avg_return_pct: average_return(symbol_outcomes),
        best_return_pct: best_return(symbol_outcomes),
        worst_return_pct: worst_return(symbol_outcomes)
      }
    end)
    |> Enum.sort_by(
      &{sort_rate(&1.win_rate), decimal_sort(&1.avg_return_pct), &1.resolved},
      :desc
    )
    |> Enum.take(10)
  end

  defp resolved_outcomes(outcomes) do
    Enum.filter(outcomes, &(&1.label in @resolved_labels))
  end

  defp count_label(outcomes, label), do: Enum.count(outcomes, &(&1.label == label))

  defp rating_for(%Outcome{analysis: %Analysis{recommendation: recommendation}}) do
    case recommendation do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> "unrated"
          rating -> rating
        end

      _other ->
        "unrated"
    end
  end

  defp rating_for(_outcome), do: "unrated"

  defp percent(_count, 0), do: 0.0

  defp percent(count, total) do
    count
    |> Kernel./(total)
    |> Kernel.*(100)
    |> Float.round(2)
  end

  defp average_return(outcomes) do
    outcomes
    |> return_values()
    |> case do
      [] ->
        nil

      values ->
        values
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        |> Decimal.div(Decimal.new(length(values)))
        |> Decimal.round(4)
    end
  end

  defp best_return(outcomes) do
    outcomes
    |> return_values()
    |> Enum.reduce(nil, fn value, acc ->
      if is_nil(acc) or Decimal.compare(value, acc) == :gt, do: value, else: acc
    end)
  end

  defp worst_return(outcomes) do
    outcomes
    |> return_values()
    |> Enum.reduce(nil, fn value, acc ->
      if is_nil(acc) or Decimal.compare(value, acc) == :lt, do: value, else: acc
    end)
  end

  defp return_values(outcomes) do
    outcomes
    |> Enum.map(& &1.return_pct)
    |> Enum.reject(&is_nil/1)
  end

  defp sort_rate(nil), do: -1.0
  defp sort_rate(rate), do: rate

  defp decimal_sort(nil), do: Decimal.new("-999999")
  defp decimal_sort(%Decimal{} = value), do: Decimal.to_float(value)
end
