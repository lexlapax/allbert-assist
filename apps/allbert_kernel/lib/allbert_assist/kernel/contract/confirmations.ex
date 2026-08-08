defmodule AllbertAssist.Kernel.Contract.Confirmations do
  @moduledoc """
  Durable confirmation records for relocated Security Review.

  Review summarizes pending and resolved confirmations for the operator. The
  durable store is residual substrate, so the listing arrives as a port; the
  confirmation lifecycle itself is untouched and still runs through its existing
  create-and-approve path.

  Unbound, the listing is empty. An empty review shows no outstanding approval
  rather than inventing one, and cannot approve anything.
  """

  alias AllbertAssist.Kernel.Contract

  @callback list(keyword()) :: [term()]

  @doc "List durable confirmation records matching `opts`."
  @spec list(keyword()) :: [term()]
  def list(opts) do
    case Contract.fetch(:confirmations) do
      {:ok, implementation} -> implementation.list(opts)
      {:error, _unbound} -> []
    end
  end
end
