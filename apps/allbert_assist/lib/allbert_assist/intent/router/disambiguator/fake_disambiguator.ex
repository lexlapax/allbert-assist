defmodule AllbertAssist.Intent.Router.Disambiguator.FakeDisambiguator do
  @moduledoc """
  Test selection boundary. Returns whatever is configured via
  `Application.put_env(:allbert_assist, :intent_router_fake_selection, result)`,
  where `result` is `{:ok, selection_map}` or `{:error, reason}`.
  """
  @behaviour AllbertAssist.Intent.Router.Disambiguator.Behaviour

  @impl true
  def select(_query, _shortlist, _context, _opts) do
    Application.get_env(:allbert_assist, :intent_router_fake_selection, {:error, :no_fake_selection})
  end
end
