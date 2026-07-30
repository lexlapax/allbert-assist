defmodule AllbertAssist.Search.QueryTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Search.Query

  test "parses the closed safe grammar and typed filters" do
    assert {:ok, parsed} =
             Query.parse(%{
               query: ~s(café "release notes" ship*),
               order: :newest,
               limit: 50,
               filters: %{
                 authors: ["operator", :assistant],
                 surfaces: ["tui"],
                 thread_ids: ["thread-1"],
                 after: "2026-07-01T00:00:00.000000Z",
                 before: "2026-08-01T00:00:00.000000Z",
                 origin_scope: "local_operator",
                 e2ee: false
               }
             })

    assert parsed.match == ~s("café" "release notes" "ship"*)
    assert parsed.order == :newest
    assert parsed.filters.authors == [:operator, :assistant]
    refute Query.trace_summary(parsed) |> Map.has_key?(:query)
    refute Query.trace_summary(parsed) |> Map.has_key?(:match)
  end

  test "rejects raw FTS operators, punctuation, columns, and invalid prefixes" do
    for query <- ["one OR two", "one + two", "title:secret", "(one)", "a*", "one*two"] do
      assert {:error, :invalid_query} = Query.parse(%{query: query})
    end
  end

  test "enforces request, clause, phrase, limit, and filter bounds" do
    assert {:error, :invalid_query} = Query.parse(%{query: "ok", unknown: true})

    assert {:error, :invalid_query} =
             Query.parse(%{query: Enum.join(List.duplicate("x", 17), " ")})

    assert {:error, :invalid_query} =
             Query.parse(%{query: ~s("#{Enum.join(List.duplicate("x", 13), " ")}")})

    assert {:error, :invalid_limit} = Query.parse(%{query: "ok", limit: 101})
    assert {:error, :invalid_filter} = Query.parse(%{query: "ok", filters: %{unknown: true}})
    assert {:error, :invalid_filter} = Query.parse(%{query: "ok", filters: %{authors: []}})
  end
end
