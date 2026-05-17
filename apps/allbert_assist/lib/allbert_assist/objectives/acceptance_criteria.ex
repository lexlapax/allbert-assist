defmodule AllbertAssist.Objectives.AcceptanceCriteria do
  @moduledoc """
  Validation helpers for v0.24 structured objective acceptance criteria.

  Criteria are operator-inspectable JSON maps, not free-form model output.
  """

  @required_clause_kinds ~w[step_completed_with_action observation_contains]
  @needs_more_clause_kinds ~w[completed_step_count_below]

  @doc "Return the single-step fixture criteria used by M1 tests."
  @spec single_step(map()) :: map()
  def single_step(attrs \\ %{}) do
    action = Map.get(attrs, :action, "StockSage.Actions.RunAnalysis")

    %{
      "min_completed_steps" => 1,
      "required" => [
        %{
          "kind" => "step_completed_with_action",
          "action" => action,
          "min_count" => 1
        }
      ],
      "needs_more_when" => [
        %{"kind" => "completed_step_count_below", "value" => 1}
      ],
      "summary" => Map.get(attrs, :summary, "One matching step completes.")
    }
  end

  @doc "Decode criteria JSON."
  @spec decode(String.t() | nil) :: {:ok, map() | nil} | {:error, term()}
  def decode(nil), do: {:ok, nil}

  def decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, other} -> {:error, {:expected_map, other}}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  @doc "Validate JSON-encoded criteria text."
  @spec validate_text(String.t() | nil) :: :ok | {:error, term()}
  def validate_text(nil), do: :ok

  def validate_text(text) when is_binary(text) do
    with {:ok, criteria} <- decode(text) do
      validate(criteria)
    end
  end

  @doc "Validate decoded criteria."
  @spec validate(map() | nil) :: :ok | {:error, term()}
  def validate(nil), do: :ok

  def validate(%{} = criteria) do
    with :ok <- validate_summary(criteria),
         :ok <- validate_integer(criteria, "min_completed_steps"),
         :ok <- validate_clauses(Map.get(criteria, "required", []), @required_clause_kinds),
         :ok <-
           validate_clauses(Map.get(criteria, "needs_more_when", []), @needs_more_clause_kinds) do
      :ok
    end
  end

  def validate(other), do: {:error, {:expected_map, other}}

  @doc "Encode validated criteria to JSON."
  @spec encode!(map()) :: String.t()
  def encode!(%{} = criteria) do
    :ok = validate(criteria)
    Jason.encode!(criteria)
  end

  defp validate_summary(%{"summary" => summary}) when is_binary(summary) do
    if String.length(summary) <= 500, do: :ok, else: {:error, {:too_long, "summary"}}
  end

  defp validate_summary(%{"summary" => other}), do: {:error, {:expected_string, "summary", other}}
  defp validate_summary(_criteria), do: :ok

  defp validate_integer(criteria, key) do
    case Map.get(criteria, key) do
      nil -> :ok
      value when is_integer(value) and value >= 0 -> :ok
      other -> {:error, {:expected_non_negative_integer, key, other}}
    end
  end

  defp validate_clauses(clauses, allowed) when is_list(clauses) do
    Enum.reduce_while(clauses, :ok, fn clause, :ok ->
      case validate_clause(clause, allowed) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_clauses(other, _allowed), do: {:error, {:expected_clause_list, other}}

  defp validate_clause(%{"kind" => kind}, allowed) when is_binary(kind) do
    if kind in allowed, do: :ok, else: {:error, {:unknown_clause_kind, kind}}
  end

  defp validate_clause(%{} = clause, _allowed), do: {:error, {:missing_clause_kind, clause}}
  defp validate_clause(other, _allowed), do: {:error, {:expected_clause_map, other}}
end
