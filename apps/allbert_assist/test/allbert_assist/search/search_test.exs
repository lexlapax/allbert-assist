defmodule AllbertAssist.SearchTest do
  use AllbertAssist.DataCase, async: false
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Repo
  alias AllbertAssist.Search
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-search-query-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    KeyCustody.invalidate(:all)
    start_supervised!({Projection, root: Path.join(root, "projection"), name: Projection})

    on_exit(fn ->
      KeyCustody.invalidate(:all)
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "local query reauthorizes stale leading hits, refills, and returns bounded DTOs" do
    assert {:ok, _setting} = Settings.put("search.snippet.max_bytes", 64)
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Refill")

    messages =
      for index <- 1..12 do
        assert {:ok, message} =
                 local_message(
                   thread,
                   "searchable refill message #{index} " <> String.duplicate("x", 100)
                 )

        message
      end

    assert {:ok, _build} = Projection.rebuild("alice")

    messages
    |> Enum.take(-5)
    |> Enum.each(&Repo.delete!/1)

    assert {:ok, page} =
             Search.query(
               %{query: "searchable", order: :newest, limit: 4},
               %{operator_id: "alice", channel: "tui"}
             )

    assert length(page.results) == 4
    assert page.scanned_count == 9
    assert page.filtered_count == 5
    assert Enum.all?(page.results, &(byte_size(&1.snippet) <= 64))
    assert Enum.all?(page.results, &(&1.source_type == :conversation))
    assert is_binary(page.next_cursor)
    refute page.incomplete
  end

  test "missing verified generation returns typed not-ready without canonical scan fallback" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Not ready")
    assert {:ok, _message} = local_message(thread, "canonical only search source")

    assert {:error, :search_not_ready} =
             Search.query(%{query: "canonical only"}, %{operator_id: "alice", channel: "web"})
  end

  test "cursor binds exact request and stale generation revision fails explicitly" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Cursor")
    assert {:ok, first} = local_message(thread, "cursor source first")
    assert {:ok, second} = local_message(thread, "cursor source second")
    assert {:ok, _build} = Projection.rebuild("alice")

    context = %{operator_id: "alice", channel: "web"}
    request = %{query: "cursor source", order: :oldest, limit: 1}
    assert {:ok, first_page} = Search.query(request, context)
    assert [%{source_id: first_id}] = first_page.results
    assert first_id == first.id

    assert {:ok, second_page} =
             Search.query(Map.put(request, :cursor, first_page.next_cursor), context)

    assert [%{source_id: second_id}] = second_page.results
    assert second_id == second.id
    assert second_page.next_cursor == nil

    assert {:error, :invalid_query} =
             Search.query(
               Map.merge(request, %{query: "changed", cursor: first_page.next_cursor}),
               context
             )

    assert {:ok, [{:ok, envelope}]} =
             Corpus.rehydrate_and_authorize(
               "alice",
               [second.id],
               %{consumer: :search, origin_scope: :local_operator, e2ee?: false}
             )

    assert {:ok, _revision} = Projection.upsert(envelope)

    assert {:error, :search_changed} =
             Search.query(Map.put(request, :cursor, first_page.next_cursor), context)
  end

  test "Search-owned trace summary omits query, MATCH text, and filter operands" do
    summary =
      Search.trace_summary(%{
        query: "private search words",
        filters: %{thread_ids: ["private-thread"], surfaces: ["tui"]}
      })

    serialized = inspect(summary)
    refute serialized =~ "private search words"
    refute serialized =~ "private-thread"
    refute serialized =~ ~s("private")
    assert summary.filter_kinds == [:surfaces, :thread_ids]
    assert summary.filter_count == 2
  end

  test "five full stale batches stop at the frozen 500-candidate refill budget" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Budget")
    base = ~U[2026-07-29 12:00:00.000000Z]

    rows =
      for index <- 0..500 do
        %{
          id: "msg-search-budget-#{String.pad_leading(Integer.to_string(index), 4, "0")}",
          thread_id: thread.id,
          user_id: "alice",
          role: "user",
          content: "budget needle #{index}",
          action_log: %{},
          metadata: %{"channel" => "tui"},
          inserted_at: DateTime.add(base, index, :second)
        }
      end

    assert {501, nil} = Repo.insert_all(Message, rows)
    assert {:ok, _build} = Projection.rebuild("alice")

    stale_ids = rows |> Enum.drop(1) |> Enum.map(& &1.id)

    from(message in Message, where: message.id in ^stale_ids)
    |> Repo.delete_all()

    assert {:ok, page} =
             Search.query(
               %{query: "budget needle", order: :newest, limit: 1},
               %{operator_id: "alice", channel: "cli"}
             )

    assert page.results == []
    assert page.scanned_count == 500
    assert page.filtered_count == 500
    assert page.incomplete
    assert page.incomplete_reason == :reauthorization_scan_budget
    assert is_binary(page.next_cursor)
  end

  defp local_message(thread, content) do
    Conversations.append_user_message(thread, content, metadata: %{"channel" => "tui"})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
