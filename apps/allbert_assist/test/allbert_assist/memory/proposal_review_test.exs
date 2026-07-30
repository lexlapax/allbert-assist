defmodule AllbertAssist.Memory.ProposalReviewTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Forget
  alias AllbertAssist.Memory.ProposalReview
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Memory.Proposals.Batch
  alias AllbertAssist.Memory.Proposals.Proposal
  alias AllbertAssist.Memory.SpanProvenance
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_memory = Application.get_env(:allbert_assist, AllbertAssist.Memory)
    original_home = System.get_env("ALLBERT_HOME")

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-proposal-review-#{System.unique_integer([:positive])}"
      )

    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, AllbertAssist.Memory)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    System.put_env("ALLBERT_HOME", root)
    KeyCustody.invalidate(:all)

    assert {:ok, _setting} = Settings.put("memory.consolidation.enabled", true)

    assert {:ok, _setting} =
             Settings.put("memory.collection.origin_grants", ["local_operator"])

    on_exit(fn ->
      restore_env(Settings, original_settings)
      restore_env(Paths, original_paths)
      restore_env(AllbertAssist.Memory, original_memory)
      restore_system_env("ALLBERT_HOME", original_home)
      KeyCustody.invalidate(:all)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "applying freezes one decision, rejects changes, appends once, and scrubs Repo content" do
    proposal = proposal("tea")
    binding = proposal_binding(proposal)
    decision = %{operation: :keep}

    assert {:ok, applying} =
             ProposalReview.begin_review(proposal.id, binding, decision, "operator:alice")

    assert applying.status == "applying"
    assert applying.applying_payload["claim"]["value"] == "tea"
    assert applying.applying_transition_id == applying.applying_payload["transition_id"]
    assert {:ok, _claim_id} = Ecto.UUID.cast(applying.applying_payload["claim_id"])
    assert {:ok, _transition_id} = Ecto.UUID.cast(applying.applying_payload["transition_id"])
    assert {:ok, _revision_id} = Ecto.UUID.cast(applying.applying_payload["revision_id"])
    pattern = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    assert applying.applying_payload["claim_id"] =~ pattern
    assert applying.applying_payload["transition_id"] =~ pattern
    assert applying.applying_payload["revision_id"] =~ pattern

    assert {:error, :applying_decision_changed} =
             ProposalReview.begin_review(
               proposal.id,
               binding,
               %{operation: :reject},
               "operator:alice"
             )

    assert {:ok, result} = ProposalReview.resume(proposal.id)
    assert result.status == "kept"
    assert result.result["outcome"] == "kept"

    terminal = Repo.get!(Proposal, proposal.id)
    assert terminal.status == "kept"
    assert terminal.proposed_claim == %{"content_scrubbed" => true}
    assert terminal.span_provenance == %{"content_scrubbed" => true}
    assert is_nil(terminal.applying_payload)
    refute inspect(terminal) =~ "tea"

    assert {:ok, current} = Claims.current(proposal.id)
    assert current["payload"]["value"] == "tea"
    assert current["transition_id"] == applying.applying_transition_id

    assert {:ok, same_result} = ProposalReview.resume(proposal.id)
    assert same_result == result
    assert {:ok, stream} = Claims.read(proposal.id)
    assert length(stream.records) == 1
  end

  test "lost collection authority after applying marks stale and writes no claim" do
    proposal = proposal("metric")

    assert {:ok, applying} =
             ProposalReview.begin_review(
               proposal.id,
               proposal_binding(proposal),
               %{operation: "keep"},
               "operator:alice"
             )

    assert applying.status == "applying"
    assert {:ok, _setting} = Settings.put("memory.collection.origin_grants", [])

    assert {:ok, result} = ProposalReview.resume(proposal.id)
    assert result.status == "stale"
    assert result.result["reason"] == "origin_grant_required"
    assert {:error, :not_found} = Claims.read(proposal.id)

    stale = Repo.get!(Proposal, proposal.id)
    refute inspect(stale) =~ "metric"
  end

  test "managed reconciliation resumes applying proposals and batches from durable state" do
    applying_proposal = proposal("resumable")

    assert {:ok, _applying} =
             ProposalReview.begin_review(
               applying_proposal.id,
               proposal_binding(applying_proposal),
               %{operation: :keep},
               "operator:alice"
             )

    batched_proposal = proposal("batched")

    assert {:ok, batch} =
             Proposals.freeze_batch(
               "alice",
               "default",
               [batch_binding(batched_proposal)],
               "operator:alice"
             )

    assert {:ok, _batch} = batch |> Ecto.Changeset.change(status: "applying") |> Repo.update()

    assert {:ok, proposal_recovery} = ProposalReview.reconcile_applying()
    assert proposal_recovery.attempted_count == 1
    assert proposal_recovery.completed_count == 1
    assert proposal_recovery.retryable_error_count == 0
    assert [%{proposal_id: proposal_id, outcome: "kept"}] = proposal_recovery.items
    assert proposal_id == applying_proposal.id

    assert {:ok, batch_recovery} = ProposalReview.reconcile_batches()
    assert batch_recovery.attempted_count == 1
    assert batch_recovery.completed_count == 1
    assert batch_recovery.retryable_error_count == 0
    assert [%{batch_id: batch_id, outcome: "complete"}] = batch_recovery.items
    assert batch_id == batch.id

    assert {:ok, empty} = ProposalReview.reconcile_applying()
    assert empty.attempted_count == 0
    assert {:ok, stream} = Claims.read(applying_proposal.id)
    assert length(stream.records) == 1
  end

  test "reject writes exact suppression, stays content-free, and is idempotent" do
    proposal = proposal("coffee")

    assert {:ok, result} =
             ProposalReview.review(
               proposal.id,
               proposal_binding(proposal),
               %{operation: :reject},
               "operator:alice"
             )

    assert result.status == "rejected"
    refute inspect(Repo.get!(Proposal, proposal.id)) =~ "coffee"
    assert {:error, :not_found} = Claims.read(proposal.id)

    assert {:ok, same} =
             ProposalReview.review(
               proposal.id,
               proposal_binding(proposal),
               %{operation: :reject},
               "operator:alice"
             )

    assert same == result
  end

  test "Forget immediately scrubs matching applying content and frozen batch references" do
    matching = proposal("forgotten value")
    survivor = proposal("surviving value")

    assert {:ok, batch} =
             Proposals.freeze_batch(
               "alice",
               "default",
               [batch_binding(matching), batch_binding(survivor)],
               "operator:alice"
             )

    assert {:ok, _applying} =
             ProposalReview.begin_review(
               matching.id,
               proposal_binding(matching),
               %{operation: :keep},
               "operator:alice"
             )

    claim_id = Ecto.UUID.generate()
    assert {:ok, claim} = Claims.append(claim_id, nil, claim_transition("forgotten value"))

    assert {:error, :memory_projection_unavailable} =
             Forget.forget(
               claim_id,
               claim.tail_digest,
               "operator:alice",
               "operator_requested"
             )

    forgotten = Repo.get!(Proposal, matching.id)
    assert forgotten.status == "forgotten"
    assert is_nil(forgotten.applying_payload)
    refute inspect(forgotten) =~ "forgotten value"

    retained_batch = Repo.get!(Batch, batch.id)
    assert Enum.map(retained_batch.bindings["items"], & &1["proposal_id"]) == [survivor.id]

    assert Enum.any?(
             retained_batch.results["items"],
             &(&1["proposal_id"] == matching.id and &1["outcome"] == "forgotten")
           )

    assert {:ok, completed} = ProposalReview.resume_batch(batch.id, "operator:alice")
    assert completed.status == "complete"
    assert {:ok, _claim} = Claims.current(survivor.id)
    assert {:error, :not_found} = Claims.read(matching.id)
  end

  test "preview returns bounded transient context and stale bindings fail before mutation" do
    proposal = proposal("tea")

    assert {:ok, preview} = ProposalReview.preview(proposal.id, "alice")
    assert Enum.any?(preview.context.messages, &(&1.content == "I prefer tea."))
    assert preview.context.truncated == false

    assert {:error, :stale_proposal_binding} =
             ProposalReview.review(
               proposal.id,
               %{revision: 99, proposal_digest: proposal.proposal_digest},
               %{operation: :keep},
               "operator:alice"
             )

    assert Repo.get!(Proposal, proposal.id).status == "pending"
  end

  test "frozen Keep All excludes protected rows and records partial idempotent outcomes" do
    first = proposal("tea")
    second = proposal("coffee")
    bindings = [batch_binding(first), batch_binding(second)]

    assert {:ok, batch} =
             Proposals.freeze_batch("alice", "default", bindings, "operator:alice")

    second_source_id = second.source_evidence["source_id"]
    assert {:ok, _message} = Message |> Repo.get!(second_source_id) |> Repo.delete()

    assert {:ok, result} = ProposalReview.resume_batch(batch.id, "operator:alice")
    assert result.status == "complete"

    outcomes = Map.new(result.results, &{&1["proposal_id"], &1["outcome"]})
    assert outcomes[first.id] == "kept"
    assert outcomes[second.id] == "stale"
    assert {:ok, _claim} = Claims.current(first.id)
    assert {:error, :not_found} = Claims.read(second.id)

    assert {:ok, same} = ProposalReview.resume_batch(batch.id, "operator:alice")
    assert same == result

    protected_source = source("My dependent has a private appointment.")

    assert {:ok, %{proposal: protected}} =
             Proposals.propose_protected(protected_source, %{
               classification: "protected_dependent",
               classifier_digest: digest("protected-dependent-v1"),
               category: "notes",
               namespace: "default",
               run_id: "run-protected",
               extractor_profile: "deterministic_v1",
               extractor_version: 1
             })

    assert {:error, :protected_proposal_not_bulk_eligible} =
             Proposals.freeze_batch(
               "alice",
               "default",
               [batch_binding(protected)],
               "operator:alice"
             )
  end

  defp proposal(value) do
    source = source("I prefer #{value}.")
    attrs = attrs(source, value)

    assert {:ok, %{outcome: :created, proposal: proposal}} = Proposals.propose(source, attrs)
    proposal
  end

  defp source(content) do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Review source")

    assert {:ok, message} =
             Conversations.append_user_message(thread, content, metadata: %{"channel" => "tui"})

    policy = %{consumer: :memory, origin_scope: :local_operator, e2ee?: false}
    assert {:ok, snapshot} = Corpus.snapshot("alice", policy)
    assert {:ok, page} = Corpus.page(snapshot, nil, 100)
    source = Enum.find(page.items, &(&1.source_id == message.id))
    assert source
    source
  end

  defp attrs(source, value) do
    {:ok, subject} = span("subject", source, "I", "operator_pronoun_v1")
    {:ok, predicate} = span("predicate", source, "prefer", "identity_v1")
    {:ok, object} = span("value", source, value, "identity_v1")

    %{
      proposed_claim: %{
        subject: "operator:alice",
        predicate: "prefer",
        value: value,
        valid_from: nil,
        valid_to: nil,
        relationship: nil
      },
      span_provenance: %{fields: [subject, predicate, object]},
      category: "preferences",
      namespace: "default",
      run_id: "run-review",
      extractor_profile: "deterministic_v1",
      extractor_version: 1
    }
  end

  defp span(field, source, raw, transform) do
    {start, length} = :binary.match(source.content, raw)
    SpanProvenance.build(field, source, start, start + length, transform)
  end

  defp proposal_binding(proposal),
    do: %{revision: proposal.revision, proposal_digest: proposal.proposal_digest}

  defp batch_binding(proposal),
    do: Map.put(proposal_binding(proposal), :proposal_id, proposal.id)

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp claim_transition(value) do
    %{
      revision_id: Ecto.UUID.generate(),
      transition_id: Ecto.UUID.generate(),
      state: "kept",
      recorded_at: "2026-07-29T12:00:00Z",
      valid_from: nil,
      valid_to: nil,
      actor: "operator:alice",
      action: "remember",
      value: value
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
