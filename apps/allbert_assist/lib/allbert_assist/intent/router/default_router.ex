defmodule AllbertAssist.Intent.Router.DefaultRouter do
  @moduledoc """
  Default intent router (ADR 0060).

  Runs **Stage 1** (the embedding prefilter) → **Stage 2** (constrained LLM
  disambiguation + confidence gate). The engine wiring lands in M5. When the
  prefilter cannot run (embeddings/index unavailable) or Stage 2 is unavailable,
  it defers so the caller uses the deterministic ladder.
  """
  @behaviour AllbertAssist.Intent.Router.Behaviour

  alias AllbertAssist.Intent.Router.Disambiguator
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Intent.Router.Prefilter

  @impl true
  def route(request, _candidates, context) do
    query = request |> Map.get(:text, "") |> to_string()

    case Prefilter.shortlist(query) do
      {:ok, %{shortlist: shortlist, margin: margin}} ->
        Disambiguator.disambiguate(query, shortlist, margin, context)

      {:fallback, reason} ->
        {:ok, Outcome.defer(:prefilter_fallback, %{reason: inspect(reason)})}
    end
  end
end
