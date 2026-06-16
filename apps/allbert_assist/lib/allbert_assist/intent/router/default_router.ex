defmodule AllbertAssist.Intent.Router.DefaultRouter do
  @moduledoc """
  Default intent router (ADR 0060).

  M2 runs **Stage 1** (the embedding prefilter) and carries the shortlist on a
  `:defer` outcome; **Stage 2** (constrained LLM disambiguation → execute /
  clarify) replaces the defer in M3, and the engine wiring lands in M5. When the
  prefilter cannot run (embeddings/index unavailable) it defers with the reason
  so the caller uses the deterministic ladder.
  """
  @behaviour AllbertAssist.Intent.Router.Behaviour

  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Intent.Router.Prefilter

  @impl true
  def route(request, _candidates, _context) do
    query = request |> Map.get(:text, "") |> to_string()

    case Prefilter.shortlist(query) do
      {:ok, %{shortlist: shortlist, margin: margin}} ->
        {:ok, Outcome.defer(:stage1_only, %{shortlist: shortlist, margin: margin})}

      {:fallback, reason} ->
        {:ok, Outcome.defer(:prefilter_fallback, %{reason: inspect(reason)})}
    end
  end
end
