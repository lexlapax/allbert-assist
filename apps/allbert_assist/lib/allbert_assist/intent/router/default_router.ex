defmodule AllbertAssist.Intent.Router.DefaultRouter do
  @moduledoc """
  Default intent router (ADR 0060).

  v0.54 M0 stub: defers to the deterministic engine decision. The two-stage
  local pipeline — embedding prefilter (M2) → constrained LLM disambiguation
  (M3) → confidence gate — is built across M1-M3 and wired in M5.
  """
  @behaviour AllbertAssist.Intent.Router.Behaviour

  alias AllbertAssist.Intent.Router.Outcome

  @impl true
  def route(_request, _candidates, _context), do: {:ok, Outcome.defer(:not_implemented)}
end
