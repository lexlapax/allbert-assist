defmodule AllbertAssist.Memory.Proposals do
  @moduledoc """
  Inert review-state storage for Memory proposals.

  This context is deliberately not a GenServer. The existing application Repo
  owns proposal transactions, while `Memory.Claims` remains the sole authority
  for kept claims. Every conversation admission reauthorizes through Corpus;
  no proposal, batch, or suppression grants claim mutation authority.
  """

  import Ecto.Query

  alias AllbertAssist.Conversations.SourceEnvelope
  alias AllbertAssist.Memory.Claims.Format
  alias AllbertAssist.Memory.CollectionPolicy
  alias AllbertAssist.Memory.Forget
  alias AllbertAssist.Memory.Proposals.Batch
  alias AllbertAssist.Memory.Proposals.Proposal
  alias AllbertAssist.Memory.Proposals.Suppression
  alias AllbertAssist.Memory.SecretFilter
  alias AllbertAssist.Memory.SpanProvenance
  alias AllbertAssist.Repo

  @normalizer_version 1
  @pending_cap 50
  @digest_pattern ~r/^sha256:[0-9a-f]{64}$/
  @ordinary_classification "ordinary"
  @protected_classifications ~w[protected_third_party protected_minor protected_dependent]

  @doc "Create or find one ordinary proposal after current source authorization."
  def propose(%SourceEnvelope{} = source, attrs) when is_map(attrs) do
    with {:ok, sources} <- reauthorize_sources(source, attrs),
         current <- List.last(sources),
         {:ok, normalized} <- normalize_ordinary(current, sources, attrs),
         :ok <- secret_free(normalized.content),
         {:ok, false} <- Forget.suppressed_value?(normalized.value) do
      insert_bounded(normalized.attrs)
    else
      {:ok, true} -> {:error, :forgotten_value_suppressed}
      {:error, reason} -> {:error, reason}
    end
  end

  def propose(_source, _attrs), do: {:error, :invalid_proposal}

  @doc "Persist one extractor result without adding a second extraction path."
  def propose_extracted(extracted, run_id) when is_map(extracted) and is_binary(run_id) do
    sources = Map.get(extracted, :source_envelopes, Map.get(extracted, "source_envelopes", []))

    case List.last(sources) do
      %SourceEnvelope{} = primary ->
        propose(primary, %{
          proposed_claim:
            Map.get(extracted, :proposed_claim, Map.get(extracted, "proposed_claim")),
          span_provenance:
            Map.get(extracted, :span_provenance, Map.get(extracted, "span_provenance")),
          category: Map.get(extracted, :category, Map.get(extracted, "category", "notes")),
          namespace: "default",
          run_id: run_id,
          extractor_profile:
            Map.get(extracted, :extractor_profile, Map.get(extracted, "extractor_profile")),
          extractor_version:
            Map.get(extracted, :extractor_version, Map.get(extracted, "extractor_version")),
          source_envelopes: sources
        })

      _other ->
        {:error, :missing_extractor_sources}
    end
  end

  def propose_extracted(_extracted, _run_id), do: {:error, :invalid_extractor_result}

  @doc "Create or find a content-free protected stub after current source authorization."
  def propose_protected(%SourceEnvelope{} = source, attrs) when is_map(attrs) do
    with {:ok, current} <- CollectionPolicy.reauthorize(source),
         {:ok, normalized} <- normalize_protected(current, attrs) do
      insert_bounded(normalized)
    end
  end

  def propose_protected(_source, _attrs), do: {:error, :invalid_protected_proposal}

  @doc "Count only active review/apply rows for one operator namespace."
  def pending_count(operator_id, namespace \\ "default") do
    Proposal
    |> where(
      [proposal],
      proposal.operator_id == ^operator_id and proposal.namespace == ^namespace and
        proposal.status in ["pending", "applying"]
    )
    |> Repo.aggregate(:count)
  end

  @doc "List proposal rows without fetching or caching conversation excerpts."
  def list(operator_id, namespace \\ "default", opts \\ []) do
    statuses = Keyword.get(opts, :statuses, ["pending", "applying"])

    Proposal
    |> where(
      [proposal],
      proposal.operator_id == ^operator_id and proposal.namespace == ^namespace and
        proposal.status in ^statuses
    )
    |> order_by([proposal], asc: proposal.inserted_at, asc: proposal.id)
    |> Repo.all()
  end

  @doc "Return the shared surface DTO without internal applying payloads."
  def to_review_map(%Proposal{} = proposal) do
    %{
      id: proposal.id,
      operator_id: proposal.operator_id,
      namespace: proposal.namespace,
      category: proposal.category,
      kind: proposal.kind,
      status: proposal.status,
      classification: proposal.classification,
      proposed_claim: review_claim(proposal),
      revision: proposal.revision,
      proposal_digest: proposal.proposal_digest,
      source_ids: evidence_source_ids(proposal.source_evidence),
      inserted_at: proposal.inserted_at,
      reviewed_at: proposal.reviewed_at,
      result: proposal.result
    }
  end

  @doc "Freeze an exact visible ordinary proposal set for Keep All."
  def freeze_batch(operator_id, namespace, bindings, requested_by)
      when is_binary(operator_id) and is_binary(namespace) and is_list(bindings) and
             is_binary(requested_by) and bindings != [] and length(bindings) <= @pending_cap do
    normalized = Enum.map(bindings, &normalize_binding/1)

    with :ok <- unique_batch_bindings(normalized),
         {:ok, proposals} <- bound_proposals(operator_id, namespace, normalized),
         :ok <- ordinary_batch(proposals) do
      attrs = %{
        id: Ecto.UUID.generate(),
        operator_id: operator_id,
        namespace: namespace,
        status: "pending",
        bindings: %{"items" => normalized},
        results: %{"items" => []},
        requested_by: String.trim(requested_by)
      }

      %Batch{}
      |> Batch.changeset(attrs)
      |> Repo.insert()
    end
  end

  def freeze_batch(_operator_id, _namespace, _bindings, _requested_by),
    do: {:error, :invalid_batch}

  @doc false
  def proposal_digest(namespace, claim) do
    digest(
      Format.canonical_json(%{
        "normalizer_version" => @normalizer_version,
        "namespace" => namespace,
        "claim" => claim
      })
    )
  end

  defp insert_bounded(attrs) do
    Repo.transaction(
      fn ->
        case existing(attrs) do
          %Proposal{} = proposal ->
            %{outcome: :existing, proposal: proposal}

          nil ->
            insert_new(attrs)
        end
      end,
      mode: :immediate
    )
  end

  defp insert_new(attrs) do
    cond do
      suppressed?(attrs) ->
        Repo.rollback(:unchanged_reject_suppressed)

      pending_count(attrs.operator_id, attrs.namespace) >= @pending_cap ->
        Repo.rollback(:pending_cap_reached)

      true ->
        %Proposal{}
        |> Proposal.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, proposal} -> %{outcome: :created, proposal: proposal}
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  defp existing(attrs) do
    Repo.one(
      from(proposal in Proposal,
        where:
          proposal.operator_id == ^attrs.operator_id and
            proposal.namespace == ^attrs.namespace and
            proposal.idempotency_key == ^attrs.idempotency_key,
        limit: 1
      )
    )
  end

  defp suppressed?(attrs) do
    Repo.exists?(
      from(suppression in Suppression,
        where:
          suppression.operator_id == ^attrs.operator_id and
            suppression.namespace == ^attrs.namespace and
            suppression.proposal_digest == ^attrs.proposal_digest and
            suppression.source_digest == ^attrs.source_digest and
            suppression.normalizer_version == ^@normalizer_version
      )
    )
  end

  defp normalize_binding(binding) when is_map(binding) do
    %{
      "proposal_id" => Map.get(binding, :proposal_id, Map.get(binding, "proposal_id")),
      "revision" => Map.get(binding, :revision, Map.get(binding, "revision")),
      "proposal_digest" => Map.get(binding, :proposal_digest, Map.get(binding, "proposal_digest"))
    }
  end

  defp normalize_binding(_binding), do: %{}

  defp unique_batch_bindings(bindings) do
    ids = Enum.map(bindings, & &1["proposal_id"])

    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and Enum.uniq(ids) == ids,
      do: :ok,
      else: {:error, :duplicate_or_invalid_batch_binding}
  end

  defp bound_proposals(operator_id, namespace, bindings) do
    ids = Enum.map(bindings, & &1["proposal_id"])

    proposals =
      Proposal
      |> where(
        [proposal],
        proposal.operator_id == ^operator_id and proposal.namespace == ^namespace and
          proposal.id in ^ids
      )
      |> Repo.all()

    by_id = Map.new(proposals, &{&1.id, &1})

    if Enum.all?(bindings, &binding_matches?(by_id[&1["proposal_id"]], &1)),
      do: {:ok, Enum.map(ids, &by_id[&1])},
      else: {:error, :stale_proposal_binding}
  end

  defp binding_matches?(%Proposal{} = proposal, binding) do
    proposal.status == "pending" and proposal.revision == binding["revision"] and
      proposal.proposal_digest == binding["proposal_digest"]
  end

  defp binding_matches?(_proposal, _binding), do: false

  defp ordinary_batch(proposals) do
    if Enum.all?(proposals, &(&1.kind == "ordinary" and &1.classification == "ordinary")),
      do: :ok,
      else: {:error, :protected_proposal_not_bulk_eligible}
  end

  defp review_claim(%Proposal{kind: "protected_stub"}), do: nil

  defp review_claim(%Proposal{status: status}) when status in ~w[kept rejected stale forgotten],
    do: nil

  defp review_claim(proposal), do: proposal.proposed_claim

  defp evidence_source_ids(evidence) do
    evidence = stringify(evidence)

    case evidence["refs"] do
      refs when is_list(refs) -> Enum.map(refs, & &1["source_id"])
      _other -> [evidence["source_id"]]
    end
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_ordinary(source, sources, attrs) do
    with {:ok, namespace} <- required(attrs, :namespace, "default"),
         {:ok, category} <- required(attrs, :category, "notes"),
         {:ok, claim} <- required_map(attrs, :proposed_claim),
         {:ok, value} <- required_binary(claim, :value),
         {:ok, spans} <- required_map(attrs, :span_provenance),
         {:ok, spans} <- SpanProvenance.verify(claim, spans, sources),
         {:ok, run_id} <- required(attrs, :run_id),
         {:ok, extractor_profile} <- required(attrs, :extractor_profile),
         {:ok, extractor_version} <- positive_integer(attrs, :extractor_version),
         :ok <- validate_digest(source.content_digest) do
      proposal_digest = proposal_digest(namespace, claim)

      result =
        base_attrs(
          source,
          sources,
          namespace,
          category,
          run_id,
          extractor_profile,
          extractor_version
        )
        |> Map.merge(%{
          kind: "ordinary",
          classification: @ordinary_classification,
          proposed_claim: claim,
          span_provenance: spans,
          proposal_digest: proposal_digest,
          idempotency_key: idempotency_key(source, proposal_digest, extractor_version)
        })

      {:ok, %{attrs: result, value: value, content: [claim, spans]}}
    end
  end

  defp normalize_protected(source, attrs) do
    with {:ok, namespace} <- required(attrs, :namespace, "default"),
         {:ok, category} <- required(attrs, :category, "notes"),
         {:ok, classification} <- required(attrs, :classification),
         true <- classification in @protected_classifications || {:error, :invalid_classification},
         {:ok, classifier_digest} <- required(attrs, :classifier_digest),
         :ok <- validate_digest(classifier_digest),
         {:ok, run_id} <- required(attrs, :run_id),
         {:ok, extractor_profile} <- required(attrs, :extractor_profile),
         {:ok, extractor_version} <- positive_integer(attrs, :extractor_version),
         :ok <- protected_content_absent(attrs),
         :ok <- validate_digest(source.content_digest) do
      stub_digest =
        digest(
          Format.canonical_json(%{
            "normalizer_version" => @normalizer_version,
            "namespace" => namespace,
            "classification" => classification,
            "classifier_digest" => classifier_digest,
            "source_digest" => source.content_digest
          })
        )

      {:ok,
       base_attrs(
         source,
         [source],
         namespace,
         category,
         run_id,
         extractor_profile,
         extractor_version
       )
       |> Map.merge(%{
         kind: "protected_stub",
         classification: classification,
         proposed_claim: nil,
         span_provenance: nil,
         proposal_digest: stub_digest,
         idempotency_key: idempotency_key(source, stub_digest, extractor_version),
         source_evidence: source_evidence([source], %{"classifier_digest" => classifier_digest})
       })}
    end
  end

  defp base_attrs(
         source,
         sources,
         namespace,
         category,
         run_id,
         extractor_profile,
         extractor_version
       ) do
    %{
      id: Ecto.UUID.generate(),
      operator_id: source.operator_id,
      namespace: namespace,
      category: category,
      status: "pending",
      source_evidence: source_evidence(sources),
      source_digest: source.content_digest,
      principal_digest: source.principal_digest,
      origin_scope: Atom.to_string(source.origin_scope),
      extractor_profile: extractor_profile,
      extractor_version: extractor_version,
      run_id: run_id,
      revision: 1,
      result: %{}
    }
  end

  defp source_evidence(sources, extra \\ %{}) when is_list(sources) do
    refs = Enum.map(sources, &source_ref/1)
    primary = List.last(refs)

    primary
    |> Map.put("schema_version", 1)
    |> Map.put("refs", refs)
    |> Map.merge(extra)
  end

  defp source_ref(source) do
    %{
      "source_type" => Atom.to_string(source.source_type),
      "source_id" => source.source_id,
      "thread_id" => source.thread_id,
      "content_digest" => source.content_digest,
      "principal_digest" => source.principal_digest,
      "origin_scope" => Atom.to_string(source.origin_scope),
      "origin_overlays" => Enum.map(source.origin_overlays, &Atom.to_string/1),
      "source_version" => source.source_version
    }
  end

  defp idempotency_key(source, proposal_digest, extractor_version) do
    digest(
      Format.canonical_json(%{
        "source_id" => source.source_id,
        "source_digest" => source.content_digest,
        "proposal_digest" => proposal_digest,
        "extractor_version" => extractor_version
      })
    )
  end

  defp reauthorize_sources(source, attrs) do
    sources =
      Map.get(attrs, :source_envelopes, Map.get(attrs, "source_envelopes", [source]))

    with true <- (is_list(sources) and sources != []) || {:error, :invalid_source_envelopes},
         %SourceEnvelope{source_id: primary_id} <- List.last(sources),
         true <- primary_id == source.source_id || {:error, :primary_source_mismatch} do
      Enum.reduce_while(sources, {:ok, []}, &reauthorize_source/2)
      |> case do
        {:ok, current} -> {:ok, Enum.reverse(current)}
        error -> error
      end
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_source_envelopes}
    end
  end

  defp reauthorize_source(candidate, {:ok, acc}) do
    case CollectionPolicy.reauthorize(candidate) do
      {:ok, current} -> {:cont, {:ok, [current | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp protected_content_absent(attrs) do
    content_keys = [:proposed_claim, "proposed_claim", :span_provenance, "span_provenance"]

    if Enum.all?(content_keys, &is_nil(Map.get(attrs, &1))),
      do: :ok,
      else: {:error, :protected_stub_content_forbidden}
  end

  defp required(attrs, key, fallback \\ nil) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), fallback))

    if is_binary(value) and String.trim(value) != "",
      do: {:ok, String.trim(value)},
      else: {:error, {:missing_or_invalid, key}}
  end

  defp required_map(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    if is_map(value) and map_size(value) > 0,
      do: {:ok, stringify(value)},
      else: {:error, {:missing_or_invalid, key}}
  end

  defp required_binary(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    if is_binary(value) and String.trim(value) != "",
      do: {:ok, String.trim(value)},
      else: {:error, {:missing_or_invalid, key}}
  end

  defp positive_integer(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, {:missing_or_invalid, key}}
  end

  defp validate_digest(value) do
    if is_binary(value) and Regex.match?(@digest_pattern, value),
      do: :ok,
      else: {:error, :invalid_digest}
  end

  defp secret_free(value) do
    if SecretFilter.secret_bearing?(value), do: {:error, :secret_filtered}, else: :ok
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp stringify(value), do: value

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
