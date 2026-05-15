defmodule AllbertAssist.Intent.Ranker do
  @moduledoc """
  Deterministic scoring helpers for intent candidates.

  v0.19 starts with conservative scoring. Later milestones add registry and
  app/surface inputs here instead of growing private agent predicates.
  """

  alias AllbertAssist.Intent.Candidate

  @spec rank([Candidate.t() | map()], map()) :: [Candidate.t() | map()]
  def rank(candidates, _context \\ %{}) when is_list(candidates) do
    Enum.sort_by(candidates, &score_for_sort/1, :desc)
  end

  @spec selected([Candidate.t() | map()]) :: Candidate.t() | map() | nil
  def selected(candidates) when is_list(candidates) do
    candidates
    |> rank(%{})
    |> Enum.find(fn candidate ->
      field(candidate, :status) in [:selected, :candidate]
    end)
  end

  @spec score(term()) :: float()
  def score(candidate), do: normalize_score(field(candidate, :score, 0.0))

  @spec exact_text_match?(String.t(), String.t() | nil) :: boolean()
  def exact_text_match?(text, value) when is_binary(text) and is_binary(value) do
    text
    |> String.downcase()
    |> String.contains?(String.downcase(value))
  end

  def exact_text_match?(_text, _value), do: false

  defp score_for_sort(candidate) do
    selected_boost = if field(candidate, :selected?) == true, do: 1.0, else: 0.0
    status_boost = if field(candidate, :status) == :selected, do: 0.5, else: 0.0
    score(candidate) + selected_boost + status_boost
  end

  defp normalize_score(value) when is_integer(value), do: normalize_score(value / 1)
  defp normalize_score(value) when is_float(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_score(_value), do: 0.0

  defp field(value, key, default \\ nil)

  defp field(%_struct{} = struct, key, default), do: Map.get(struct, key, default)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_value, _key, default), do: default
end
