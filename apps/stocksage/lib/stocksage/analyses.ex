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

  def summarize_trends(user_id, opts \\ []) do
    outcomes = list_outcomes(user_id, opts)

    counts =
      Enum.reduce(outcomes, %{}, fn outcome, acc ->
        Map.update(acc, outcome.label, 1, &(&1 + 1))
      end)

    %{
      user_id: Domain.normalize_user_id(user_id),
      symbol: opts |> Keyword.get(:symbol) |> Domain.normalize_symbol(),
      returned: length(outcomes),
      counts: counts,
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
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

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
end
