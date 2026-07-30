defmodule AllbertAssist.Memory.ProposalReviewTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.ProposalReview
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Memory.Proposals.Proposal
  alias AllbertAssist.Memory.SpanProvenance
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_home = System.get_env("ALLBERT_HOME")

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-proposal-review-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    System.put_env("ALLBERT_HOME", root)
    KeyCustody.invalidate(:all)

    assert {:ok, _setting} = Settings.put("memory.consolidation.enabled", true)

    assert {:ok, _setting} =
             Settings.put("memory.collection.origin_grants", ["local_operator"])

    on_exit(fn ->
      restore_env(Settings, original_settings)
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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
