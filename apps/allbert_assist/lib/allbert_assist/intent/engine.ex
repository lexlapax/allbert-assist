defmodule AllbertAssist.Intent.Engine do
  @moduledoc """
  Registry-aware intent engine entrypoint.

  M1 keeps behavior conservative: it can produce a direct-answer decision and
  annotate existing decisions with bounded candidate metadata. Later v0.19
  milestones add real registry collection, app/surface ranking, and optional
  model assistance behind this module.
  """

  alias AllbertAssist.Intent.Candidate
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.Ranker

  @spec decide(map()) :: {:ok, Decision.t()} | {:error, term()}
  def decide(request) when is_map(request) do
    attrs = %{
      intent: :direct_answer,
      reason: "The prompt is handled by the default direct-answer route.",
      selected_skill: "direct-answer",
      selected_action: "direct_answer",
      trace_metadata: %{source_text: field(request, :text)},
      context: %{request: request}
    }

    with {:ok, decision} <- Decision.new(attrs) do
      {:ok, put_candidate_metadata(decision)}
    end
  end

  def decide(value), do: {:error, {:invalid_request, value}}

  @spec put_candidate_metadata(Decision.t()) :: Decision.t()
  def put_candidate_metadata(%Decision{} = decision) do
    selected = Candidate.selected_from_decision(decision)
    candidates = [selected] |> Ranker.rank(%{}) |> Candidate.bound()

    trace_metadata =
      decision.trace_metadata
      |> Map.put(:intent_candidates, %{
        selected: selected |> Candidate.to_map(),
        rejected: [],
        total: length(candidates),
        engine_version: "v0.19-m1"
      })

    %{decision | trace_metadata: trace_metadata}
  end

  @spec put_candidate_metadata(map()) :: map()
  def put_candidate_metadata(%{} = response) do
    case Map.get(response, :decision) || Map.get(response, "decision") do
      %Decision{} = decision -> Map.put(response, :decision, put_candidate_metadata(decision))
      _other -> response
    end
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
