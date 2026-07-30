defmodule AllbertAssist.Conversations.CorpusTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Settings

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-corpus-test-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "snapshot pages equal timestamps without duplicates and excludes later appends" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Stable page")

    messages =
      for index <- 1..4 do
        assert {:ok, message} = local_message(thread, "message #{index}")
        message
      end

    timestamp = ~U[2026-07-29 12:00:00.000000Z]
    ids = Enum.map(messages, & &1.id)

    from(message in Message, where: message.id in ^ids)
    |> Repo.update_all(set: [inserted_at: timestamp])

    assert {:ok, snapshot} = Corpus.snapshot("alice", local_search_policy())
    assert {:ok, late} = local_message(thread, "after high water")

    assert {:ok, first} = Corpus.page(snapshot, nil, 2)
    assert {:ok, second} = Corpus.page(snapshot, first.cursor, 2)
    assert {:ok, terminal} = Corpus.page(snapshot, second.cursor, 2)

    seen = Enum.map(first.items ++ second.items ++ terminal.items, & &1.source_id)

    assert seen == Enum.sort(ids)
    refute late.id in seen
    assert Enum.uniq(seen) == seen
    assert terminal.items == []
    assert terminal.exhausted?
  end

  test "incremental page accepts only a typed prior high-water position" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Incremental page")
    assert {:ok, first} = local_message(thread, "first")
    assert {:ok, snapshot} = Corpus.snapshot("alice", local_search_policy())

    assert {:ok, page} =
             Corpus.page_after(
               snapshot,
               %{inserted_at: first.inserted_at, source_id: first.id},
               20
             )

    assert page.items == []
    assert page.exhausted?
    assert {:error, :invalid_cursor} = Corpus.page_after(snapshot, %{source_id: first.id}, 20)
  end

  test "rehydration preserves order, checks digests, and bounds context without truncating source" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Context")

    messages =
      for index <- 1..11 do
        assert {:ok, message} = local_message(thread, "message #{index}")
        message
      end

    policy = local_search_policy()
    assert {:ok, snapshot} = Corpus.snapshot("alice", policy)
    assert {:ok, page} = Corpus.page(snapshot, nil, 20)
    envelopes = Map.new(page.items, &{&1.source_id, &1})
    [first, second | _rest] = messages

    refs = [
      %{source_id: second.id, content_digest: envelopes[second.id].content_digest},
      %{source_id: first.id, content_digest: "sha256:" <> String.duplicate("0", 64)},
      "msg_missing"
    ]

    assert {:ok, [{:ok, second_envelope}, {:error, :digest_mismatch}, {:error, :missing}]} =
             Corpus.rehydrate_and_authorize("alice", refs, policy)

    assert second_envelope.source_id == second.id
    source = Enum.at(messages, 5)

    assert {:ok, %{messages: context, truncated: true}} =
             Corpus.conversation_context("alice", source.id, policy)

    assert length(context) == 9
    assert Enum.any?(context, &(&1.source_id == source.id))

    assert {:ok, oversized} =
             local_message(thread, String.duplicate("x", 32_769))

    assert {:error, :source_context_too_large} =
             Corpus.conversation_context("alice", oversized.id, policy)
  end

  test "batch rehydration preloads one bounded candidate set instead of querying per ref" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Batch rehydrate")

    refs =
      for index <- 1..100 do
        assert {:ok, message} = local_message(thread, "batch message #{index}")
        message.id
      end

    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:allbert_assist, :repo, :query],
        fn _event, _measurements, _metadata, owner -> send(owner, :corpus_batch_query) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, results} =
             Corpus.rehydrate_and_authorize("alice", refs, local_search_policy())

    assert length(results) == 100
    assert Enum.all?(results, &match?({:ok, _envelope}, &1))
    assert query_count() in 1..3
  end

  test "consumer grant transitions invalidate only that consumer snapshot" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Grant epoch")
    assert {:ok, _message} = local_message(thread, "eligible")
    assert {:ok, search_snapshot} = Corpus.snapshot("alice", local_search_policy())

    assert {:ok, _setting} = Settings.put("search.origin_grants", [])
    assert {:error, :origin_grant_required} = Corpus.page(search_snapshot, nil, 10)

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(:search, :local_operator, false, %{actor: "test"})

    assert Corpus.eligibility_epoch(:search) > search_snapshot.eligibility_epoch
    assert {:error, :origin_grant_required} = Corpus.page(search_snapshot, nil, 10)
    assert {:error, :origin_grant_required} = Corpus.snapshot("alice", local_search_policy())
    assert Corpus.eligibility_epoch(:memory) == 0
  end

  test "Memory context may include assistant turns while source pages remain operator-only" do
    assert {:ok, _setting} = Settings.put("memory.consolidation.enabled", true)
    assert {:ok, _epoch} = Corpus.set_origin_grant(:memory, :local_operator, true)
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Memory context")
    assert {:ok, first} = local_message(thread, "I prefer verified context.")

    assert {:ok, assistant} =
             Conversations.append_assistant_message(thread, "Assistant-only context.",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, source} = local_message(thread, "I prefer grounded evidence.")
    policy = %{consumer: :memory, origin_scope: :local_operator, e2ee?: false}

    assert {:ok, snapshot} = Corpus.snapshot("alice", policy)
    assert {:ok, page} = Corpus.page(snapshot, nil, 20)
    assert Enum.map(page.items, & &1.source_id) == [first.id, source.id]

    assert {:ok, %{messages: context}} =
             Corpus.conversation_context("alice", source.id, policy)

    assert Enum.any?(context, &(&1.source_id == assistant.id and &1.author == :assistant))
  end

  defp local_message(thread, content) do
    Conversations.append_user_message(thread, content, metadata: %{"channel" => "tui"})
  end

  defp local_search_policy do
    %{consumer: :search, origin_scope: :local_operator, e2ee?: false}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp query_count(count \\ 0) do
    receive do
      :corpus_batch_query -> query_count(count + 1)
    after
      0 -> count
    end
  end
end
