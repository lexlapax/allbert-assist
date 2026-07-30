defmodule AllbertAssist.Memory.CollectionPolicy do
  @moduledoc """
  Reauthorizes verified conversation evidence for Memory collection.

  This is a plain policy module rather than a process: it derives no durable
  state and delegates current principal, origin-grant, and digest authority to
  `AllbertAssist.Conversations.Corpus` on every admission or retry.
  """

  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.SourceEnvelope

  @doc "Re-read one source under the current Memory-specific collection grant."
  @spec reauthorize(SourceEnvelope.t()) :: {:ok, SourceEnvelope.t()} | {:error, term()}
  def reauthorize(%SourceEnvelope{} = source) do
    with :ok <- eligible_source(source),
         policy <- policy(source),
         {:ok, [{:ok, current}]} <-
           Corpus.rehydrate_authorized(
             source.operator_id,
             [%{source_id: source.source_id, content_digest: source.content_digest}],
             policy
           ),
         :ok <- unchanged_identity(source, current),
         :ok <- eligible_source(current) do
      {:ok, current}
    else
      {:ok, [{:error, reason}]} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :source_reauthorization_failed}
    end
  end

  def reauthorize(_source), do: {:error, :invalid_source_envelope}

  @doc "Rehydrate every content-free proposal evidence ref under its current grant."
  def reauthorize_evidence(operator_id, evidence)
      when is_binary(operator_id) and is_map(evidence) do
    evidence
    |> evidence_refs()
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case reauthorize_ref(operator_id, ref) do
        {:ok, source} -> {:cont, {:ok, [source | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      error -> error
    end
  end

  def reauthorize_evidence(_operator_id, _evidence), do: {:error, :invalid_source_evidence}

  @doc "Return the exact Corpus policy represented by a verified source."
  def policy(%SourceEnvelope{} = source) do
    %{
      consumer: :memory,
      origin_scope: source.origin_scope,
      e2ee?: :e2ee_operator in source.origin_overlays
    }
  end

  defp eligible_source(source) do
    checks = [
      source.source_type == :conversation,
      source.author == :operator,
      source.trust == :private_operator,
      source.origin_scope in [:local_operator, :mapped_operator_dm],
      is_binary(source.operator_id) and source.operator_id != "",
      is_binary(source.principal_digest) and source.principal_digest != "",
      is_binary(source.content_digest) and source.content_digest != ""
    ]

    if Enum.all?(checks), do: :ok, else: {:error, :ineligible_memory_source}
  end

  defp unchanged_identity(expected, current) do
    if expected.operator_id == current.operator_id and
         expected.principal_digest == current.principal_digest and
         expected.origin_scope == current.origin_scope and
         expected.origin_overlays == current.origin_overlays,
       do: :ok,
       else: {:error, :source_identity_changed}
  end

  defp reauthorize_ref(operator_id, ref) when is_map(ref) do
    ref = stringify(ref)

    with {:ok, origin_scope} <- origin_scope(ref["origin_scope"]),
         policy <- %{
           consumer: :memory,
           origin_scope: origin_scope,
           e2ee?: "e2ee_operator" in List.wrap(ref["origin_overlays"])
         },
         {:ok, [{:ok, current}]} <-
           Corpus.rehydrate_authorized(
             operator_id,
             [%{source_id: ref["source_id"], content_digest: ref["content_digest"]}],
             policy
           ),
         true <-
           current.principal_digest == ref["principal_digest"] ||
             {:error, :source_identity_changed},
         :ok <- eligible_source(current) do
      {:ok, current}
    else
      {:ok, [{:error, reason}]} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :source_reauthorization_failed}
    end
  end

  defp reauthorize_ref(_operator_id, _ref), do: {:error, :invalid_source_evidence}

  defp evidence_refs(evidence) do
    evidence = stringify(evidence)

    case evidence["refs"] do
      refs when is_list(refs) and refs != [] -> refs
      _other -> [Map.drop(evidence, ["refs"])]
    end
  end

  defp origin_scope("local_operator"), do: {:ok, :local_operator}
  defp origin_scope("mapped_operator_dm"), do: {:ok, :mapped_operator_dm}
  defp origin_scope(_scope), do: {:error, :invalid_origin_scope}

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp stringify(value), do: value
end
