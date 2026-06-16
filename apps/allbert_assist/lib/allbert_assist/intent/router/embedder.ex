defmodule AllbertAssist.Intent.Router.Embedder do
  @moduledoc """
  Local text-embedding boundary for the intent router Stage 1 prefilter
  (ADR 0061). Embeds short utterances through the configured
  `intent.router_embedding_profile`.

  **Local-only:** the resolved profile must be a local endpoint; remote
  providers are rejected so routing performs no embedding egress. The
  implementation is swappable via
  `Application.put_env(:allbert_assist, :intent_router_embedder, impl)` (tests use
  `Embedder.FakeEmbedder`).
  """
  defmodule Behaviour do
    @moduledoc "Behaviour for intent-router embedders (ADR 0061)."
    @callback embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  end

  @default_impl AllbertAssist.Intent.Router.Embedder.ReqLLMEmbedder

  @spec embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed(texts, opts \\ []) when is_list(texts) do
    impl().embed(texts, opts)
  end

  @doc "Cosine similarity of two equal-length vectors (0.0 when either is zero)."
  @spec cosine([float()], [float()]) :: float()
  def cosine(a, b) when is_list(a) and is_list(b) and length(a) == length(b) do
    {dot, na, nb} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, na, nb} ->
        {dot + x * y, na + x * x, nb + y * y}
      end)

    denom = :math.sqrt(na) * :math.sqrt(nb)
    if denom == 0.0, do: 0.0, else: dot / denom
  end

  def cosine(_a, _b), do: 0.0

  defp impl, do: Application.get_env(:allbert_assist, :intent_router_embedder, @default_impl)
end
