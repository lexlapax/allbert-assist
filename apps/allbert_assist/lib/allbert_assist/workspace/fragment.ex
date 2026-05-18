defmodule AllbertAssist.Workspace.Fragment do
  @moduledoc """
  Workspace fragment emission boundary.

  M2 ships the envelope contract. The full signed emission pipeline is
  intentionally deferred to M7.
  """

  alias AllbertAssist.Workspace.Fragment.Envelope

  @type envelope :: Envelope.t()

  @spec emit(Envelope.t()) :: :ok | {:error, term()}
  def emit(%Envelope{}), do: {:error, :not_implemented}
  def emit(_envelope), do: {:error, :invalid_envelope}
end
