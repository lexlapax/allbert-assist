defmodule Mix.Tasks.Stocksage.QueueTest do
  use StockSage.DataCase

  import ExUnit.CaptureIO

  alias Mix.Tasks.Stocksage.Queue, as: QueueTask
  alias StockSage.Queue

  setup do
    on_exit(fn -> Mix.Task.reenable("stocksage.queue") end)
    :ok
  end

  test "creates and lists queue rows with default local user" do
    create_output =
      capture_io(fn ->
        assert :ok = QueueTask.run(["create", "tsla", "--thread-id", "thread_1"])
      end)

    assert create_output =~ "Symbol: TSLA"
    assert [%{id: queue_id}] = Queue.list_entries("local")

    Mix.Task.reenable("stocksage.queue")

    list_output =
      capture_io(fn ->
        assert :ok = QueueTask.run(["list", "--user", "local", "--status", "queued"])
      end)

    assert list_output =~ queue_id
    assert list_output =~ "TSLA"
  end

  test "user scoped queue list isolates rows" do
    assert {:ok, _entry} = Queue.create_entry(%{user_id: "alice", symbol: "aapl"})

    output =
      capture_io(fn ->
        assert :ok = QueueTask.run(["list", "--user", "bob"])
      end)

    assert output =~ "Returned: 0"
    refute output =~ "AAPL"
  end

  test "fails when user and operator differ" do
    assert_raise Mix.Error, ~r/--user alice differs from --operator bob/, fn ->
      capture_io(fn ->
        QueueTask.run(["list", "--user", "alice", "--operator", "bob"])
      end)
    end
  end
end
