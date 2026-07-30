defmodule AllbertAssist.Security.V13CrossConsumerEvalTest do
  @moduledoc "M8 revocation, deletion, and consumer-grant rejoin proofs."

  use AllbertAssist.DataCase, async: false, lane: :security_eval_serial

  alias AllbertAssist.Actions.Conversations.DeleteConversationContent
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Memory.ActiveMemory
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Projection, as: MemoryProjection
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Memory.Proposals.Proposal
  alias AllbertAssist.Memory.SpanProvenance
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Search
  alias AllbertAssist.Search.Projection, as: SearchProjection
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_runtime = Application.get_env(:allbert_assist, Runtime)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-v13-cross-eval-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)
    Application.put_env(:allbert_assist, Runtime, agent_runner: &runtime_response/2)
    KeyCustody.invalidate(:all)

    start_supervised!(
      {SearchProjection, root: Paths.search_projection_root(), name: SearchProjection}
    )

    {:ok, memory_projection} = MemoryProjection.start_link(root: Paths.memory_projection_root())

    on_exit(fn ->
      if Process.alive?(memory_projection), do: GenServer.stop(memory_projection)
      KeyCustody.invalidate(:all)
      restore_home(original_home)
      restore_env(Paths, original_paths)
      restore_env(Runtime, original_runtime)
      restore_env(Settings, original_settings)
      File.rm_rf!(home)
    end)

    assert {:ok, _setting} = Settings.put("memory.consolidation.enabled", true)
    assert {:ok, _setting} = Settings.put("memory.collection.origin_grants", ["local_operator"])

    {:ok, memory_projection: memory_projection}
  end

  test "canonical deletion suppresses Search and proposal while an independent claim remains", %{
    memory_projection: memory_projection
  } do
    claim_id = Ecto.UUID.generate()

    assert {:ok, kept} =
             Claims.append(claim_id, nil, claim_transition("rejoin sentinel preference"))

    assert {:ok, _build} = MemoryProjection.rebuild(memory_projection)

    assert {:ok, thread} = Conversations.create_general_thread("local", "Rejoin source")

    assert {:ok, message} =
             Conversations.append_user_message(thread, "I prefer rejoin sentinel preference.",
               metadata: %{"channel" => "tui"}
             )

    source = local_source(message.id)
    proposal = proposal_for(source, "rejoin sentinel preference")
    assert {:ok, _build} = SearchProjection.rebuild("local")

    assert {:ok, before_delete} =
             Search.query(%{query: "rejoin sentinel"}, local_search_context())

    assert Enum.any?(before_delete.results, &(&1.source_id == message.id))

    assert {:ok, before_memory} = retrieve_memory(memory_projection)
    assert Enum.any?(before_memory.chunks, &(&1.claim_id == claim_id))

    assert {:ok, pending} =
             DeleteConversationContent.run(
               %{target_kind: :message, target_id: message.id},
               operator_context()
             )

    assert {:ok, deleted} =
             DeleteConversationContent.run(
               pending.confirmation["resume_params_ref"],
               approved_context()
             )

    assert deleted.status == :completed

    assert {:ok, after_delete} = Search.query(%{query: "rejoin sentinel"}, local_search_context())
    refute Enum.any?(after_delete.results, &(&1.source_id == message.id))
    assert Repo.get!(Proposal, proposal.id).status == "stale"

    assert {:ok, after_memory} = retrieve_memory(memory_projection)
    assert Enum.any?(after_memory.chunks, &(&1.claim_id == claim_id))

    assert {:ok, _archived} =
             Claims.append(
               claim_id,
               kept.tail_digest,
               claim_transition("rejoin sentinel preference", "archived")
             )

    assert {:ok, archived_memory} = retrieve_memory(memory_projection)
    refute Enum.any?(archived_memory.chunks, &(&1.claim_id == claim_id))
  end

  test "Search and Memory mapped-DM and E2EE grants are non-transitive" do
    assert {:ok, _link} = ChannelThread.link_identity(identity_attrs())

    assert {:ok, turn} =
             Runtime.submit_user_input(%{
               text: "I prefer consumer isolation.",
               channel: "slack",
               user_id: "alice",
               external_user_id: "U_ALICE",
               channel_thread_ref: slack_ref(),
               provider_message_id: "cross-consumer-seed"
             })

    assert {:ok, _epoch} = Corpus.set_origin_grant(:search, :mapped_operator_dm, true)
    assert {:ok, _epoch} = Corpus.set_origin_grant(:memory, :mapped_operator_dm, false)

    assert {:ok, search_snapshot} = Corpus.snapshot("alice", mapped_policy(:search, false))
    assert {:ok, search_page} = Corpus.page(search_snapshot, nil, 100)
    assert Enum.any?(search_page.items, &(&1.source_id == turn.user_message_id))

    assert {:error, :origin_grant_required} =
             Corpus.snapshot("alice", mapped_policy(:memory, false))

    assert {:ok, _epoch} = Corpus.set_origin_grant(:memory, :mapped_operator_dm, true)
    assert {:ok, _epoch} = Corpus.set_origin_grant(:search, :mapped_operator_dm, false)

    assert {:ok, memory_snapshot} = Corpus.snapshot("alice", mapped_policy(:memory, false))
    assert {:ok, memory_page} = Corpus.page(memory_snapshot, nil, 100)
    assert Enum.any?(memory_page.items, &(&1.source_id == turn.user_message_id))

    assert {:error, :origin_grant_required} =
             Corpus.snapshot("alice", mapped_policy(:search, false))

    assert {:ok, _epoch} = Corpus.set_origin_grant(:search, :mapped_operator_dm, true)
    assert {:ok, _epoch} = Corpus.set_origin_grant(:search, :e2ee_operator, true)
    assert {:error, :e2ee_grant_required} = Corpus.snapshot("alice", mapped_policy(:memory, true))
    assert {:ok, _snapshot} = Corpus.snapshot("alice", mapped_policy(:search, true))
  end

  defp local_source(message_id) do
    assert {:ok, snapshot} =
             Corpus.snapshot("local", mapped_policy(:memory, false, :local_operator))

    assert {:ok, page} = Corpus.page(snapshot, nil, 100)
    Enum.find(page.items, &(&1.source_id == message_id)) || flunk("missing Corpus source")
  end

  defp proposal_for(source, value) do
    {:ok, subject} = span("subject", source, "I", "operator_pronoun_v1")
    {:ok, predicate} = span("predicate", source, "prefer", "identity_v1")
    {:ok, object} = span("value", source, value, "identity_v1")

    assert {:ok, %{outcome: :created, proposal: proposal}} =
             Proposals.propose(source, %{
               proposed_claim: %{
                 subject: "operator:local",
                 predicate: "prefer",
                 value: value
               },
               span_provenance: %{fields: [subject, predicate, object]},
               category: "preferences",
               namespace: "default",
               run_id: "v13-cross-consumer",
               extractor_profile: "deterministic_v1",
               extractor_version: 1
             })

    proposal
  end

  defp span(field, source, raw, transform) do
    {start, length} = :binary.match(source.content, raw)
    SpanProvenance.build(field, source, start, start + length, transform)
  end

  defp retrieve_memory(projection) do
    ActiveMemory.retrieve("rejoin sentinel preference",
      user_id: "local",
      now: "2026-07-29T12:00:00Z",
      projection: projection
    )
  end

  defp claim_transition(value, state \\ "kept") do
    %{
      revision_id: Ecto.UUID.generate(),
      transition_id: Ecto.UUID.generate(),
      state: state,
      recorded_at: "2026-07-29T10:00:00Z",
      valid_from: nil,
      valid_to: nil,
      actor: "operator:local",
      action: if(state == "kept", do: "proposal_kept", else: "claim_archived"),
      category: "preferences",
      operator_id: "local",
      namespace: "default",
      subject: "operator",
      predicate: "preference",
      value: value
    }
  end

  defp mapped_policy(consumer, e2ee?, origin_scope \\ :mapped_operator_dm),
    do: %{consumer: consumer, origin_scope: origin_scope, e2ee?: e2ee?}

  defp local_search_context,
    do: %{operator_id: "local", user_id: "local", channel: "tui"}

  defp operator_context,
    do: %{user_id: "local", actor: "local", channel: :cli, surface: "test"}

  defp approved_context,
    do: Map.put(operator_context(), :confirmation, %{approved?: true})

  defp identity_attrs do
    %{
      owner_scope: "local",
      link_id: "operator-alice",
      user_id: "alice",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      external_user_id: "U_ALICE"
    }
  end

  defp slack_ref do
    %{
      owner_scope: "local",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      provider_thread_ref: %{
        team_id: "T0123",
        channel_id: "C0123",
        thread_ts: "1718040000.000900"
      },
      trust_class: :server_readable,
      conversation_scope: :direct
    }
  end

  defp runtime_response(_signal, request) do
    {:ok, %{message: "Runtime response: #{request.text}", status: :completed, actions: []}}
  end

  defp restore_home(nil), do: System.delete_env("ALLBERT_HOME")
  defp restore_home(value), do: System.put_env("ALLBERT_HOME", value)
  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
