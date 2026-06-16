defmodule AllbertAssist.Intent.Router.Embedder.FakeEmbedder do
  @moduledoc """
  Deterministic, offline embedder for tests. Hashes tokens into a fixed-dim
  unit vector so shared vocabulary yields higher cosine similarity (good enough
  to exercise the Stage 1 prefilter without a live model).

  Force an error with
  `Application.put_env(:allbert_assist, :intent_router_embedder_error, reason)`.
  """
  @behaviour AllbertAssist.Intent.Router.Embedder.Behaviour

  @dim 64

  @impl true
  def embed(texts, _opts) when is_list(texts) do
    case Application.get_env(:allbert_assist, :intent_router_embedder_error) do
      nil -> {:ok, Enum.map(texts, &vector/1)}
      reason -> {:error, reason}
    end
  end

  @doc "The deterministic unit vector for a string (exposed for test assertions)."
  @spec vector(String.t()) :: [float()]
  def vector(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.reduce(List.duplicate(0.0, @dim), fn token, acc ->
      idx = :erlang.phash2(token, @dim)
      List.update_at(acc, idx, &(&1 + 1.0))
    end)
    |> normalize()
  end

  defp normalize(vec) do
    magnitude = :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))
    if magnitude == 0.0, do: vec, else: Enum.map(vec, &(&1 / magnitude))
  end
end
