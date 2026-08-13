defmodule AllbertAssist.Actions.MemoryProposalActionsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Memory.ListMemoryProposals
  alias AllbertAssist.Actions.Memory.ReviewMemoryProposal
  alias AllbertAssist.Actions.Memory.ReviewMemoryProposalBatch
  alias AllbertAssist.Actions.Memory.ShowMemoryProposal
  alias AllbertAssist.CLI.Areas.Memory, as: MemoryCLI
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Memory.Proposals.Proposal
  alias AllbertAssist.Memory.SpanProvenance
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody
  alias AllbertAssist.TestSupport.ReadyEffectContext

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_home = System.get_env("ALLBERT_HOME")

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-proposal-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    System.put_env("ALLBERT_HOME", root)
    KeyCustody.invalidate(:all)

    assert {:ok, _setting} =
             Settings.put(
               "memory.consolidation.enabled",
               true,
               ReadyEffectContext.context()
             )

    assert {:ok, _setting} =
             Settings.put(
               "memory.collection.origin_grants",
               ["local_operator"],
               ReadyEffectContext.context()
             )

    on_exit(fn ->
      restore_env(Settings, original_settings)
      restore_system_env("ALLBERT_HOME", original_home)
      KeyCustody.invalidate(:all)
      File.rm_rf!(root)
    end)

    %{context: %{user_id: "alice", request: %{user_id: "alice", channel: :tui}}}
  end

  test "shared list/show/review actions keep exactly one proposal", %{context: context} do
    proposal = proposal("tea")

    assert {:ok, listed} = ListMemoryProposals.run(%{}, context)
    assert listed.status == :completed
    assert [%{id: id, proposed_claim: %{"value" => "tea"}}] = listed.proposals
    assert id == proposal.id

    assert {:ok, shown} = ShowMemoryProposal.run(%{proposal_id: proposal.id}, context)
    assert shown.status == :completed
    assert shown.proposal.id == proposal.id
    assert Enum.any?(shown.context.messages, &(&1.content == "I prefer tea."))

    assert {:ok, reviewed} =
             ReviewMemoryProposal.run(
               %{
                 proposal_id: proposal.id,
                 revision: proposal.revision,
                 proposal_digest: proposal.proposal_digest,
                 operation: "keep"
               },
               context
             )

    assert reviewed.status == :completed
    assert reviewed.result.status == "kept"
    assert {:ok, current} = Claims.current(proposal.id)
    assert current["payload"]["value"] == "tea"

    assert {:ok, after_review} = ListMemoryProposals.run(%{}, context)
    assert after_review.proposals == []
  end

  test "batch action freezes exact bindings and memory_write denial cannot review", %{
    context: context
  } do
    first = proposal("tea")
    second = proposal("coffee")

    bindings =
      Enum.map([first, second], fn proposal ->
        %{
          proposal_id: proposal.id,
          revision: proposal.revision,
          proposal_digest: proposal.proposal_digest
        }
      end)

    assert {:ok, batch} =
             ReviewMemoryProposalBatch.run(%{bindings: bindings}, context)

    assert batch.status == :completed
    assert length(batch.result.results) == 2

    denied = proposal("water")

    assert {:ok, _setting} =
             Settings.put(
               "permissions.memory_write",
               "denied",
               ReadyEffectContext.context()
             )

    assert {:ok, response} =
             ReviewMemoryProposal.run(
               %{
                 proposal_id: denied.id,
                 revision: denied.revision,
                 proposal_digest: denied.proposal_digest,
                 operation: "keep"
               },
               context
             )

    assert response.status == :denied
    assert {:error, :not_found} = Claims.read(denied.id)
  end

  test "packaged CLI lists, shows, and reviews through the shared actions", %{context: context} do
    proposal = proposal("tea")

    assert {list_output, 0} = MemoryCLI.dispatch(["proposals", "--user", "alice"], context)
    assert list_output =~ proposal.id
    assert list_output =~ "value=\"tea\""

    assert {show_output, 0} =
             MemoryCLI.dispatch(["proposal", proposal.id, "--user", "alice"], context)

    assert show_output =~ "context_messages="
    assert show_output =~ "\"value\" => \"tea\""

    assert {review_output, 0} =
             MemoryCLI.dispatch(
               [
                 "proposal-review",
                 proposal.id,
                 "--revision",
                 Integer.to_string(proposal.revision),
                 "--digest",
                 proposal.proposal_digest,
                 "--operation",
                 "keep",
                 "--user",
                 "alice"
               ],
               context
             )

    assert review_output =~ "proposal_id=#{proposal.id}"
    assert review_output =~ "status=kept"
    assert {:ok, current} = Claims.current(proposal.id)
    assert current["payload"]["value"] == "tea"
  end

  test "proposal listing scrubs revoked sources before returning DTO content", %{context: context} do
    proposal = proposal("tea")

    assert {:ok, _setting} =
             Settings.put(
               "memory.collection.origin_grants",
               [],
               ReadyEffectContext.context()
             )

    assert {:ok, listed} = ListMemoryProposals.run(%{}, context)
    assert listed.status == :completed
    assert listed.proposals == []

    stale = AllbertAssist.Repo.get!(Proposal, proposal.id)
    assert stale.status == "stale"
    assert stale.proposed_claim == %{"content_scrubbed" => true}
    assert stale.span_provenance == %{"content_scrubbed" => true}
    refute inspect(stale) =~ "tea"
  end

  defp proposal(value) do
    source = source("I prefer #{value}.")
    {:ok, subject} = span("subject", source, "I", "operator_pronoun_v1")
    {:ok, predicate} = span("predicate", source, "prefer", "identity_v1")
    {:ok, object} = span("value", source, value, "identity_v1")

    attrs = %{
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
      run_id: "run-actions",
      extractor_profile: "deterministic_v1",
      extractor_version: 1
    }

    assert {:ok, %{proposal: proposal}} = Proposals.propose(source, attrs)
    proposal
  end

  defp source(content) do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Action source")

    assert {:ok, message} =
             Conversations.append_user_message(thread, content, metadata: %{"channel" => "tui"})

    policy = %{consumer: :memory, origin_scope: :local_operator, e2ee?: false}
    assert {:ok, snapshot} = Corpus.snapshot("alice", policy)
    assert {:ok, page} = Corpus.page(snapshot, nil, 100)
    Enum.find(page.items, &(&1.source_id == message.id))
  end

  defp span(field, source, raw, transform) do
    {start, length} = :binary.match(source.content, raw)
    SpanProvenance.build(field, source, start, start + length, transform)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
