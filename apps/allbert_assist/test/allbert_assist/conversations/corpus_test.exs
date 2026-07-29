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

  test "consumer grant transitions invalidate only that consumer snapshot" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Grant epoch")
    assert {:ok, _message} = local_message(thread, "eligible")
    assert {:ok, search_snapshot} = Corpus.snapshot("alice", local_search_policy())

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(:search, :local_operator, false, %{actor: "test"})

    assert {:error, :eligibility_changed} = Corpus.page(search_snapshot, nil, 10)
    assert {:error, :origin_grant_required} = Corpus.snapshot("alice", local_search_policy())
    assert Corpus.eligibility_epoch(:memory) == 0
  end

  defp local_message(thread, content) do
    Conversations.append_user_message(thread, content, metadata: %{"channel" => "tui"})
  end

  defp local_search_policy do
    %{consumer: :search, origin_scope: :local_operator, e2ee?: false}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
