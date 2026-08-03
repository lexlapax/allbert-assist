defmodule AllbertAssist.Memory.ProposalReview do
  @moduledoc """
  Frozen, crash-resumable review of inert Memory proposals.

  Repo and Markdown do not share a transaction. An `applying` proposal freezes
  one normalized decision under a deterministic transition id; retry
  reauthorizes its Corpus evidence, appends through `Memory.Claims` exactly
  once, then scrubs every durable copy of the accepted claim from Repo.
  """

  import Bitwise
  import Ecto.Query

  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Claims.Format
  alias AllbertAssist.Memory.CollectionPolicy
  alias AllbertAssist.Memory.ProjectionSync
  alias AllbertAssist.Memory.Proposals.Batch
  alias AllbertAssist.Memory.Proposals.Proposal
  alias AllbertAssist.Memory.Proposals.Suppression
  alias AllbertAssist.Memory.SpanProvenance
  alias AllbertAssist.Repo
  alias AllbertAssist.Security.Redactor

  @normalizer_version 1
  @terminal_statuses ~w[kept rejected stale forgotten error]

  @doc "Return one proposal plus transient, bounded, redacted canonical context."
  def preview(proposal_id, operator_id) do
    with %Proposal{} = proposal <- owned_proposal(proposal_id, operator_id),
         {:ok, sources} <-
           CollectionPolicy.reauthorize_evidence(operator_id, proposal.source_evidence),
         %{} = primary <- List.last(sources),
         {:ok, context} <-
           Corpus.conversation_context(
             operator_id,
             primary.source_id,
             CollectionPolicy.policy(primary)
           ) do
      {:ok,
       %{
         proposal: proposal,
         context: %{
           truncated: context.truncated,
           messages: Enum.map(context.messages, &redacted_message/1)
         }
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Freeze and apply one exact Keep/Edit/Reject decision."
  def review(proposal_id, binding, decision, actor)
      when is_map(binding) and is_map(decision) and is_binary(actor) do
    with {:ok, prepared} <- begin_review(proposal_id, binding, decision, actor) do
      case prepared.status do
        "applying" -> resume(proposal_id)
        _terminal -> {:ok, content_free_result(prepared)}
      end
    else
      {:error, reason} ->
        if stale_reason?(reason), do: mark_stale(proposal_id, reason), else: {:error, reason}
    end
  end

  def review(_proposal_id, _binding, _decision, _actor), do: {:error, :invalid_review}

  @doc false
  def begin_review(proposal_id, binding, decision, actor)
      when is_binary(proposal_id) and is_map(binding) and is_map(decision) and is_binary(actor) do
    Repo.transaction(
      fn -> prepare_locked(proposal_id, binding, decision, actor) end,
      mode: :immediate
    )
  end

  def begin_review(_proposal_id, _binding, _decision, _actor), do: {:error, :invalid_review}

  @doc "Resume one exact applying proposal after a process or host restart."
  def resume(proposal_id) when is_binary(proposal_id) do
    with %Proposal{status: "applying"} = proposal <- Repo.get(Proposal, proposal_id),
         {:ok, sources} <- reauthorize_applying(proposal),
         :ok <- verify_frozen_payload(proposal, sources),
         {:ok, append} <-
           Claims.append(claim_id(proposal), expected_tail(proposal), transition(proposal)),
         projection <- ProjectionSync.refresh(claim_id(proposal)),
         {:ok, terminal} <- finalize(proposal, append, projection) do
      {:ok, content_free_result(terminal)}
    else
      %Proposal{status: status} = proposal when status in @terminal_statuses ->
        {:ok, content_free_result(proposal)}

      %Proposal{} ->
        {:error, :proposal_not_applying}

      nil ->
        {:error, :not_found}

      {:error, reason}
      when reason in [
             :missing,
             :deleted,
             :ineligible,
             :scope_denied,
             :digest_mismatch,
             :legacy_principal_unverified,
             :legacy_origin_unverified,
             :origin_grant_required,
             :e2ee_grant_required,
             :consumer_disabled,
             :source_identity_changed
           ] ->
        mark_stale(proposal_id, reason)

      {:error, reason} ->
        record_apply_error(proposal_id, reason)
    end
  end

  def resume(_proposal_id), do: {:error, :invalid_proposal_id}

  @doc "Resume every applying proposal; intended for managed startup reconciliation."
  def reconcile_applying do
    Proposal
    |> where([proposal], proposal.status == "applying")
    |> order_by([proposal], asc: proposal.inserted_at, asc: proposal.id)
    |> Repo.all()
    |> Enum.map(&{&1.id, resume(&1.id)})
    |> summarize_recovery(:proposal_id)
  end

  @doc "Resume every applying batch through its frozen actor and per-item ledger."
  def reconcile_batches do
    Batch
    |> where([batch], batch.status == "applying")
    |> order_by([batch], asc: batch.inserted_at, asc: batch.id)
    |> Repo.all()
    |> Enum.map(&{&1.id, resume_batch(&1.id, &1.requested_by)})
    |> summarize_recovery(:batch_id)
  end

  @doc "Apply or resume one frozen ordinary Keep All batch with per-item outcomes."
  def resume_batch(batch_id, actor) when is_binary(batch_id) and is_binary(actor) do
    with %Batch{} = batch <- Repo.get(Batch, batch_id),
         :ok <- batch_actor(batch, actor) do
      resume_batch_record(batch, actor)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def resume_batch(_batch_id, _actor), do: {:error, :invalid_batch_review}

  defp resume_batch_record(%Batch{status: "forgotten"} = batch, _actor),
    do: {:ok, batch_result(batch)}

  defp resume_batch_record(batch, actor) do
    with {:ok, applying} <- mark_batch_applying(batch),
         {:ok, results} <- apply_batch_items(applying, actor),
         {:ok, complete} <- complete_batch(applying.id, results) do
      {:ok, batch_result(complete)}
    end
  end

  defp prepare_locked(proposal_id, binding, decision, actor) do
    case Repo.get(Proposal, proposal_id) do
      %Proposal{status: "pending"} = proposal ->
        with :ok <- exact_binding(proposal, binding),
             {:ok, operation} <- operation(decision),
             {:ok, sources} <-
               CollectionPolicy.reauthorize_evidence(
                 proposal.operator_id,
                 proposal.source_evidence
               ) do
          prepare_operation(proposal, sources, operation, decision, actor)
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      %Proposal{status: "applying"} = proposal ->
        with :ok <- exact_binding(proposal, binding),
             :ok <- applying_request_matches(proposal, decision, actor) do
          proposal
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      %Proposal{status: status} = proposal when status in @terminal_statuses ->
        proposal

      %Proposal{} ->
        Repo.rollback(:proposal_not_reviewable)

      nil ->
        Repo.rollback(:not_found)
    end
  end

  defp mark_batch_applying(%Batch{status: "pending"} = batch) do
    batch
    |> Ecto.Changeset.change(status: "applying")
    |> Repo.update()
  end

  defp mark_batch_applying(%Batch{status: "applying"} = batch), do: {:ok, batch}
  defp mark_batch_applying(%Batch{status: "complete"} = batch), do: {:ok, batch}
  defp mark_batch_applying(%Batch{}), do: {:error, :batch_not_reviewable}

  defp apply_batch_items(%Batch{status: "complete", results: %{"items" => items}}, _actor),
    do: {:ok, items}

  defp apply_batch_items(batch, actor) do
    existing = Map.new(batch.results["items"] || [], &{&1["proposal_id"], &1})

    batch.bindings["items"]
    |> Enum.reduce_while({:ok, []}, fn binding, {:ok, acc} ->
      item = existing[binding["proposal_id"]] || apply_batch_item(binding, actor)

      case persist_batch_item(batch.id, item) do
        {:ok, _batch} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp apply_batch_item(binding, actor) do
    review_binding = %{
      revision: binding["revision"],
      proposal_digest: binding["proposal_digest"]
    }

    case review(binding["proposal_id"], review_binding, %{operation: :keep}, actor) do
      {:ok, result} ->
        %{"proposal_id" => binding["proposal_id"], "outcome" => result.status}

      {:error, reason} ->
        %{
          "proposal_id" => binding["proposal_id"],
          "outcome" => "error",
          "reason" => inspect(reason)
        }
    end
  end

  defp persist_batch_item(batch_id, item) do
    Repo.transaction(
      fn ->
        batch = Repo.get!(Batch, batch_id)
        items = batch.results["items"] || []

        items =
          items
          |> Enum.reject(&(&1["proposal_id"] == item["proposal_id"]))
          |> Kernel.++([item])

        batch
        |> Ecto.Changeset.change(results: %{"items" => items})
        |> Repo.update!()
      end,
      mode: :immediate
    )
  end

  defp complete_batch(batch_id, results) do
    Repo.get!(Batch, batch_id)
    |> Ecto.Changeset.change(
      status: "complete",
      results: %{"items" => results},
      completed_at: now()
    )
    |> Repo.update()
  end

  defp batch_actor(batch, actor) do
    if batch.requested_by == actor,
      do: :ok,
      else: {:error, :batch_actor_mismatch}
  end

  defp batch_result(batch) do
    %{
      batch_id: batch.id,
      status: batch.status,
      operator_id: batch.operator_id,
      namespace: batch.namespace,
      results: batch.results["items"] || []
    }
  end

  defp prepare_operation(proposal, _sources, :reject, _decision, actor) do
    now = now()

    suppression_attrs = %{
      id: Ecto.UUID.generate(),
      operator_id: proposal.operator_id,
      namespace: proposal.namespace,
      proposal_digest: proposal.proposal_digest,
      source_digest: proposal.source_digest,
      normalizer_version: @normalizer_version,
      reason: "operator_rejected"
    }

    case %Suppression{} |> Suppression.changeset(suppression_attrs) |> Repo.insert() do
      {:ok, _suppression} ->
        terminal_update!(proposal, "rejected", actor, now, %{outcome: "rejected"})

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp prepare_operation(
         %Proposal{kind: "protected_stub"} = proposal,
         sources,
         operation,
         decision,
         actor
       )
       when operation in [:keep, :edit] do
    claim = decision_value(decision, "proposed_claim")
    provenance = decision_value(decision, "span_provenance")

    with true <- is_map(claim) || {:error, :protected_individual_payload_required},
         true <- is_map(provenance) || {:error, :protected_individual_payload_required},
         {:ok, verified} <- SpanProvenance.verify(claim, provenance, sources),
         {:ok, actor} <- valid_actor(actor),
         payload <-
           proposal
           |> frozen_payload(claim, verified, operation, decision, actor)
           |> Map.put("recorded_at", DateTime.to_iso8601(proposal.inserted_at)),
         decision_digest <- digest(Format.canonical_json(payload)),
         transition_id <- transition_id(proposal, decision_digest),
         payload <-
           payload
           |> Map.put("transition_id", transition_id)
           |> Map.put("revision_id", deterministic_uuid("revision", transition_id)),
         {:ok, append} <-
           Claims.append(
             payload["claim_id"],
             payload["expected_tail_digest"],
             transition(proposal, payload, "protected_individual_review")
           ),
         projection <- ProjectionSync.refresh(payload["claim_id"]) do
      terminal_update!(proposal, "kept", actor, now(), %{
        outcome: "kept",
        claim_id: append.claim_id,
        revision_id: append.revision_id,
        transition_id: append.transition_id,
        append_outcome: Atom.to_string(append.outcome),
        projection: projection
      })
    else
      {:error, reason} -> Repo.rollback(reason)
      false -> Repo.rollback(:protected_individual_payload_required)
    end
  end

  defp prepare_operation(proposal, sources, operation, decision, actor)
       when operation in [:keep, :edit] do
    claim = decision_claim(proposal, operation, decision)
    provenance = decision_provenance(proposal, operation, decision)

    with true <- is_map(claim) || {:error, :invalid_review_claim},
         true <- is_map(provenance) || {:error, :invalid_review_provenance},
         {:ok, verified} <- SpanProvenance.verify(claim, provenance, sources),
         {:ok, actor} <- valid_actor(actor),
         payload <- frozen_payload(proposal, claim, verified, operation, decision, actor),
         decision_digest <- digest(Format.canonical_json(payload)),
         transition_id <- transition_id(proposal, decision_digest),
         attrs <- %{
           status: "applying",
           proposed_claim: claim,
           span_provenance: verified,
           applying_transition_id: transition_id,
           applying_decision_digest: decision_digest,
           applying_payload:
             payload
             |> Map.put("transition_id", transition_id)
             |> Map.put("revision_id", deterministic_uuid("revision", transition_id)),
           result: %{}
         } do
      proposal
      |> Ecto.Changeset.change(attrs)
      |> Repo.update!()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp frozen_payload(proposal, claim, _provenance, operation, decision, actor) do
    %{
      "schema_version" => 1,
      "operation" => Atom.to_string(operation),
      "claim_id" => decision_value(decision, "claim_id", proposal.id),
      "expected_tail_digest" => decision_value(decision, "expected_tail_digest"),
      "category" => proposal.category,
      "claim" => claim,
      "operator_id" => proposal.operator_id,
      "namespace" => proposal.namespace,
      "actor" => actor,
      "recorded_at" => now_iso()
    }
  end

  defp transition(proposal) do
    payload = proposal.applying_payload
    transition(proposal, payload, "proposal_" <> payload["operation"])
  end

  defp transition(proposal, payload, action) do
    claim = payload["claim"]

    claim
    |> Map.merge(%{
      "revision_id" => payload["revision_id"],
      "transition_id" => payload["transition_id"],
      "state" => "kept",
      "recorded_at" => payload["recorded_at"],
      "valid_from" => claim["valid_from"],
      "valid_to" => claim["valid_to"],
      "actor" => payload["actor"],
      "action" => action,
      "category" => payload["category"],
      "operator_id" => payload["operator_id"],
      "namespace" => payload["namespace"],
      "proposal_id" => proposal.id,
      "proposal_revision" => proposal.revision,
      "proposal_digest" => proposal.proposal_digest,
      "source_evidence" => proposal.source_evidence
    })
  end

  defp verify_frozen_payload(proposal, sources) do
    payload = proposal.applying_payload

    with true <- is_map(payload) || {:error, :missing_applying_payload},
         true <-
           payload["transition_id"] == proposal.applying_transition_id ||
             {:error, :applying_transition_mismatch},
         true <-
           digest(Format.canonical_json(Map.drop(payload, ["transition_id", "revision_id"]))) ==
             proposal.applying_decision_digest || {:error, :applying_decision_mismatch},
         {:ok, _verified} <-
           SpanProvenance.verify(payload["claim"], proposal.span_provenance, sources) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize(proposal, append, projection) do
    Repo.transaction(
      fn ->
        current = Repo.get!(Proposal, proposal.id)

        if current.status == "applying" and
             current.applying_transition_id == proposal.applying_transition_id do
          terminal_update!(current, "kept", current.applying_payload["actor"], now(), %{
            outcome: "kept",
            claim_id: append.claim_id,
            revision_id: append.revision_id,
            transition_id: append.transition_id,
            append_outcome: Atom.to_string(append.outcome),
            projection: projection
          })
        else
          current
        end
      end,
      mode: :immediate
    )
  end

  defp terminal_update!(proposal, status, actor, reviewed_at, result) do
    {proposed_claim, span_provenance} =
      if proposal.kind == "protected_stub" do
        {nil, nil}
      else
        {%{"content_scrubbed" => true}, %{"content_scrubbed" => true}}
      end

    proposal
    |> Ecto.Changeset.change(%{
      status: status,
      proposed_claim: proposed_claim,
      span_provenance: span_provenance,
      applying_payload: nil,
      result: stringify(result),
      reviewed_by: actor,
      reviewed_at: reviewed_at
    })
    |> Repo.update!()
  end

  defp mark_stale(proposal_id, reason) do
    Repo.transaction(
      fn ->
        proposal = Repo.get!(Proposal, proposal_id)

        terminal_update!(proposal, "stale", "system:reauthorization", now(), %{
          outcome: "stale",
          reason: reason
        })
      end,
      mode: :immediate
    )
    |> case do
      {:ok, proposal} -> {:ok, content_free_result(proposal)}
      {:error, error} -> {:error, error}
    end
  end

  defp record_apply_error(proposal_id, reason) do
    from(proposal in Proposal,
      where: proposal.id == ^proposal_id and proposal.status == "applying"
    )
    |> Repo.update_all(
      set: [result: %{"outcome" => "retryable_error", "reason" => inspect(reason)}]
    )

    {:error, reason}
  end

  defp reauthorize_applying(proposal) do
    CollectionPolicy.reauthorize_evidence(proposal.operator_id, proposal.source_evidence)
  end

  defp exact_binding(proposal, binding) do
    revision = decision_value(binding, "revision")
    proposal_digest = decision_value(binding, "proposal_digest")

    if revision == proposal.revision and proposal_digest == proposal.proposal_digest,
      do: :ok,
      else: {:error, :stale_proposal_binding}
  end

  defp operation(decision) do
    case decision_value(decision, "operation") do
      operation when operation in ["keep", :keep] -> {:ok, :keep}
      operation when operation in ["edit", :edit] -> {:ok, :edit}
      operation when operation in ["reject", :reject] -> {:ok, :reject}
      _other -> {:error, :invalid_review_operation}
    end
  end

  defp decision_claim(proposal, :keep, _decision), do: proposal.proposed_claim
  defp decision_claim(_proposal, :edit, decision), do: decision_value(decision, "proposed_claim")
  defp decision_provenance(proposal, :keep, _decision), do: proposal.span_provenance

  defp decision_provenance(_proposal, :edit, decision),
    do: decision_value(decision, "span_provenance")

  defp applying_request_matches(proposal, decision, actor) do
    payload = proposal.applying_payload

    with {:ok, operation} <- operation(decision),
         true <-
           payload["operation"] == Atom.to_string(operation) ||
             {:error, :applying_decision_changed},
         true <- payload["actor"] == String.trim(actor) || {:error, :applying_actor_changed},
         :ok <- applying_claim_matches(payload, operation, decision) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp applying_claim_matches(_payload, :keep, _decision), do: :ok

  defp applying_claim_matches(payload, :edit, decision) do
    if stringify(decision_value(decision, "proposed_claim")) == payload["claim"],
      do: :ok,
      else: {:error, :applying_decision_changed}
  end

  defp transition_id(proposal, decision_digest) do
    deterministic_uuid(
      "transition",
      Format.canonical_json(%{
        "proposal_id" => proposal.id,
        "proposal_revision" => proposal.revision,
        "proposal_digest" => proposal.proposal_digest,
        "operator_id" => proposal.operator_id,
        "namespace" => proposal.namespace,
        "decision_digest" => decision_digest
      })
    )
  end

  defp deterministic_uuid(domain, value) do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> =
      :crypto.hash(:sha256, "allbert.memory.proposal.#{domain}.v1\0" <> value)

    c = bor(band(c, 0x0FFF), 0x5000)
    d = bor(band(d, 0x3FFF), 0x8000)

    Enum.join(
      [
        hex(a, 8),
        hex(b, 4),
        hex(c, 4),
        hex(d, 4),
        hex(e, 12)
      ],
      "-"
    )
  end

  defp hex(integer, width) do
    integer
    |> Integer.to_string(16)
    |> String.downcase(:ascii)
    |> String.pad_leading(width, "0")
  end

  defp claim_id(proposal), do: proposal.applying_payload["claim_id"]
  defp expected_tail(proposal), do: proposal.applying_payload["expected_tail_digest"]

  defp owned_proposal(proposal_id, operator_id) do
    Repo.one(
      from(proposal in Proposal,
        where: proposal.id == ^proposal_id and proposal.operator_id == ^operator_id,
        limit: 1
      )
    )
  end

  defp redacted_message(source) do
    %{
      source_id: source.source_id,
      role: source.role,
      author: source.author,
      content: Redactor.redact(source.content),
      inserted_at: source.inserted_at
    }
  end

  defp content_free_result(proposal) do
    %{
      proposal_id: proposal.id,
      status: proposal.status,
      revision: proposal.revision,
      proposal_digest: proposal.proposal_digest,
      result: proposal.result
    }
  end

  defp summarize_recovery(results, id_key) do
    items = Enum.map(results, &recovery_item(&1, id_key))

    {:ok,
     %{
       attempted_count: length(items),
       completed_count: Enum.count(items, &(&1.outcome != "retryable_error")),
       retryable_error_count: Enum.count(items, &(&1.outcome == "retryable_error")),
       items: items
     }}
  end

  defp recovery_item({id, {:ok, result}}, id_key) do
    %{id_key => id, outcome: to_string(result.status)}
  end

  defp recovery_item({id, {:error, reason}}, id_key) do
    %{id_key => id, outcome: "retryable_error", reason: inspect(reason)}
  end

  defp valid_actor(actor) do
    actor = String.trim(actor)

    if actor != "" and byte_size(actor) <= 128 and not String.contains?(actor, ["\n", "\r"]),
      do: {:ok, actor},
      else: {:error, :invalid_review_actor}
  end

  defp decision_value(map, key, default \\ nil),
    do: Map.get(map, key) || Map.get(map, decision_atom(key)) || default

  defp decision_atom("operation"), do: :operation
  defp decision_atom("revision"), do: :revision
  defp decision_atom("proposal_digest"), do: :proposal_digest
  defp decision_atom("claim_id"), do: :claim_id
  defp decision_atom("expected_tail_digest"), do: :expected_tail_digest
  defp decision_atom("proposed_claim"), do: :proposed_claim
  defp decision_atom("span_provenance"), do: :span_provenance

  defp now, do: DateTime.utc_now()
  defp now_iso, do: now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp stringify(value), do: value

  defp stale_reason?(reason) do
    reason in [
      :missing,
      :deleted,
      :ineligible,
      :scope_denied,
      :digest_mismatch,
      :legacy_principal_unverified,
      :legacy_origin_unverified,
      :origin_grant_required,
      :e2ee_grant_required,
      :consumer_disabled,
      :source_identity_changed
    ]
  end
end
