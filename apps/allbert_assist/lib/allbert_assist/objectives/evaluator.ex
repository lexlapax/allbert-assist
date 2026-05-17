defmodule AllbertAssist.Objectives.Evaluator do
  @moduledoc """
  Deterministic structured acceptance-criteria evaluator for objectives.

  The evaluator compares persisted step rows against a small JSON-compatible
  criteria map. It is intentionally not an LLM judge and does not authorize
  work.
  """

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Objective

  @type verdict :: :met | :not_met | :needs_more_steps

  @spec evaluate(Objective.t() | map() | String.t() | nil, [map() | struct()]) :: verdict()
  def evaluate(%Objective{} = objective, steps) when is_list(steps) do
    case Objectives.acceptance_criteria(objective) do
      {:ok, criteria} -> evaluate(criteria, steps)
      {:error, _reason} -> :not_met
    end
  end

  def evaluate(criteria, steps) when is_binary(criteria) and is_list(steps) do
    case Jason.decode(criteria) do
      {:ok, %{} = decoded} -> evaluate(decoded, steps)
      _other -> :not_met
    end
  end

  def evaluate(nil, steps) when is_list(steps) do
    if completed_count(steps) > 0, do: :met, else: :not_met
  end

  def evaluate(%{} = criteria, steps) when is_list(steps) do
    cond do
      not min_completed_met?(criteria, steps) ->
        needs_more_or_not_met(criteria, steps)

      required_met?(criteria, steps) ->
        :met

      needs_more?(criteria, steps) ->
        :needs_more_steps

      true ->
        :not_met
    end
  end

  def evaluate(_criteria, _steps), do: :not_met

  defp min_completed_met?(criteria, steps) do
    completed_count(steps) >= integer(criteria, "min_completed_steps", 0)
  end

  defp required_met?(criteria, steps) do
    criteria
    |> Map.get("required", [])
    |> List.wrap()
    |> Enum.all?(&clause_met?(&1, steps))
  end

  defp needs_more_or_not_met(criteria, steps) do
    if needs_more?(criteria, steps), do: :needs_more_steps, else: :not_met
  end

  defp needs_more?(criteria, steps) do
    criteria
    |> Map.get("needs_more_when", [])
    |> List.wrap()
    |> Enum.any?(&clause_met?(&1, steps))
  end

  defp clause_met?(%{"kind" => "completed_step_count_below"} = clause, steps) do
    completed_count(steps) < integer(clause, "value", 1)
  end

  defp clause_met?(%{"kind" => "step_completed_with_action"} = clause, steps) do
    action = Map.get(clause, "action")
    params_match = Map.get(clause, "params_match", %{})
    min_count = integer(clause, "min_count", 1)

    steps
    |> Enum.filter(&completed_step?/1)
    |> Enum.filter(&(field(&1, :candidate_action) == action))
    |> Enum.filter(&params_match?(&1, params_match))
    |> length()
    |> Kernel.>=(min_count)
  end

  defp clause_met?(%{"kind" => "observation_contains"} = clause, steps) do
    substring = Map.get(clause, "substring")

    is_binary(substring) and
      Enum.any?(steps, fn step ->
        completed_step?(step) and contains?(field(step, :observation_summary), substring)
      end)
  end

  defp clause_met?(_clause, _steps), do: false

  defp completed_count(steps), do: Enum.count(steps, &completed_step?/1)

  defp completed_step?(step), do: field(step, :status) in ["completed", :completed]

  defp params_match?(step, expected) when is_map(expected) do
    actual =
      step
      |> field(:action_params)
      |> decode_params()

    Enum.all?(expected, fn {key, value} ->
      Map.get(actual, key) == value or Map.get(actual, to_string(key)) == value
    end)
  end

  defp params_match?(_step, _expected), do: true

  defp decode_params(nil), do: %{}
  defp decode_params(%{} = params), do: params

  defp decode_params(params) when is_binary(params) do
    case Jason.decode(params) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  defp decode_params(_params), do: %{}

  defp contains?(value, substring) when is_binary(value) and is_binary(substring) do
    value
    |> String.downcase()
    |> String.contains?(String.downcase(substring))
  end

  defp contains?(_value, _substring), do: false

  defp integer(map, key, default) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _other -> default
    end
  end

  defp field(%_struct{} = struct, key), do: Map.get(struct, key)

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil
end
