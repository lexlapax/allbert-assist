defmodule StockSage.Domain.QueueTest do
  use StockSage.DataCase

  alias StockSage.Queue

  describe "queue entries" do
    test "create normalizes symbol and defaults lifecycle fields" do
      assert {:ok, entry} =
               Queue.create_entry(%{
                 user_id: "alice",
                 symbol: " tsla ",
                 thread_id: "thread_1"
               })

      assert entry.symbol == "TSLA"
      assert entry.status == "queued"
      assert entry.priority == "normal"
      assert entry.app_id == "stocksage"
    end

    test "filters queue entries and reads by user scope" do
      assert {:ok, alice} = Queue.create_entry(%{user_id: "alice", symbol: "aapl"})
      assert {:ok, _bob} = Queue.create_entry(%{user_id: "bob", symbol: "aapl"})

      assert [entry] = Queue.list_entries("alice", status: "queued")
      assert entry.id == alice.id
      assert {:ok, ^alice} = Queue.get_entry("alice", alice.id)
      assert {:error, :not_found} = Queue.get_entry("bob", alice.id)
    end

    test "records queue runs under the same user scope" do
      assert {:ok, entry} = Queue.create_entry(%{user_id: "alice", symbol: "nvda"})
      assert {:ok, run} = Queue.create_run(entry)

      assert run.queue_id == entry.id
      assert run.user_id == "alice"
      assert run.status == "started"
      assert [listed] = Queue.list_runs("alice", entry.id)
      assert listed.id == run.id
      assert [] = Queue.list_runs("bob", entry.id)
    end

    test "validates lifecycle enum values" do
      assert {:ok, entry} = Queue.create_entry(%{user_id: "alice", symbol: "nvda"})
      assert {:error, changeset} = Queue.update_entry_status(entry, "blocked")

      assert %{status: [_]} = errors_on(changeset)
    end
  end
end
