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
end
