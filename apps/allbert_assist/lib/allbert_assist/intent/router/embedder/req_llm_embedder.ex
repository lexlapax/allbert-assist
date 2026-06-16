defmodule AllbertAssist.Intent.Router.Embedder.ReqLLMEmbedder do
  @moduledoc """
  Default embedder (ADR 0061): resolves `intent.router_embedding_profile`,
  enforces a **local endpoint**, and embeds via `ReqLLM.embed/3`. Returns
  `{:error, :embeddings_require_local_provider}` for any non-local profile so the
  router never embeds against a remote provider.
  """
  @behaviour AllbertAssist.Intent.Router.Embedder.Behaviour

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelRuntime

  @impl true
  def embed(texts, opts) when is_list(texts) do
    with :ok <- ensure_req_llm(),
         {:ok, profile_name} <- profile_name(),
         {:ok, profile} <- Settings.resolve_model_profile(profile_name),
         :ok <- ensure_local(profile),
         {:ok, spec} <- ModelRuntime.model_spec(profile) do
      do_embed(spec, texts, profile, opts)
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp do_embed(spec, texts, profile, opts) do
    request_opts =
      profile
      |> ModelRuntime.request_opts()
      |> Keyword.merge(Keyword.take(opts, [:receive_timeout]))

    case ReqLLM.embed(spec, texts, request_opts) do
      {:ok, vectors} when is_list(vectors) -> {:ok, normalize_vectors(vectors)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_embed_result, other}}
    end
  end

  # ReqLLM returns [[float]] for a list input; guard a single-vector return too.
  defp normalize_vectors([h | _] = vectors) when is_number(h), do: [vectors]
  defp normalize_vectors(vectors), do: vectors

  defp profile_name do
    case Settings.get("intent.router_embedding_profile") do
      {:ok, name} when is_binary(name) and name != "" -> {:ok, name}
      _other -> {:error, :missing_embedding_profile}
    end
  end

  defp ensure_local(%{provider_endpoint_kind: "local_endpoint"}), do: :ok
  defp ensure_local(_profile), do: {:error, :embeddings_require_local_provider}

  defp ensure_req_llm do
    if Code.ensure_loaded?(ReqLLM), do: :ok, else: {:error, :req_llm_unavailable}
  end
end
