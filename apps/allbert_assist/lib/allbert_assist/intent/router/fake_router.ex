defmodule AllbertAssist.Intent.Router.FakeRouter do
  @moduledoc """
  Deterministic router stub for tests, mirroring
  `AllbertAssist.Intent.Classifier.FakeClassifier`. Set the outcome it returns
  via `Application.put_env(:allbert_assist, :intent_router_fake_outcome, outcome)`.
  """
  @behaviour AllbertAssist.Intent.Router.Behaviour

  alias AllbertAssist.Intent.Router.Outcome

  @impl true
  def route(_request, _candidates, _context) do
    {:ok, Application.get_env(:allbert_assist, :intent_router_fake_outcome, Outcome.defer(:fake))}
  end
end
