defmodule AllbertAssist.Memory.Lexical do
  @moduledoc """
  Deterministic lexical normalization shared by Memory projections and callers.
  """

  @stop_words ~w[a an and are about do for from in is me my of on the to what you]

  @doc "Normalize text into unique lowercase ASCII search terms."
  @spec terms(String.t()) :: [String.t()]
  def terms(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.uniq()
  end

  def terms(_text), do: []
end
