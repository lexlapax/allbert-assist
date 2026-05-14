defmodule Mix.Tasks.Allbert.ThreadsTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Conversations
  alias Mix.Tasks.Allbert.Threads

  setup do
    on_exit(fn -> Mix.Task.reenable("allbert.threads") end)
    :ok
  end

  test "lists local threads by default" do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Local topic")
    assert {:ok, _message} = Conversations.append_user_message(thread, "hello")

    output =
      capture_io(fn ->
        assert :ok = Threads.run([])
      end)

    assert output =~ thread.id
    assert output =~ "user=local"
    assert output =~ "kind=general"
    assert output =~ "app=general"
    assert output =~ "messages=1"
    assert output =~ "title=Local topic"
  end

  test "lists and shows user-scoped threads" do
    assert {:ok, alice} = Conversations.create_general_thread("alice", "Alice topic")
    assert {:ok, bob} = Conversations.create_general_thread("bob", "Bob topic")
    assert {:ok, _message} = Conversations.append_user_message(alice, "hello alice")
    assert {:ok, _message} = Conversations.append_assistant_message(alice, "hello back")
    assert {:ok, _message} = Conversations.append_user_message(bob, "hidden")

    list_output =
      capture_io(fn ->
        assert :ok = Threads.run(["--user", "alice"])
      end)

    assert list_output =~ alice.id
    refute list_output =~ bob.id

    show_output =
      capture_io(fn ->
        assert :ok = Threads.run(["--user", "alice", "--thread", alice.id])
      end)

    assert show_output =~ "Thread: #{alice.id}"
    assert show_output =~ "User: alice"
    assert show_output =~ "user: hello alice"
    assert show_output =~ "assistant: hello back"

    assert_raise Mix.Error, ~r/Thread not found/, fn ->
      Threads.run(["--user", "alice", "--thread", bob.id])
    end
  end

  test "accepts operator alias and rejects conflicting identity" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Alias topic")

    output =
      capture_io(fn ->
        assert :ok = Threads.run(["--operator", "alice"])
      end)

    assert output =~ thread.id

    assert_raise Mix.Error, ~r/--user and --operator must match/, fn ->
      Threads.run(["--user", "alice", "--operator", "bob"])
    end
  end

  test "rejects invalid limit" do
    assert_raise Mix.Error, ~r/--limit must be a positive integer/, fn ->
      Threads.run(["--limit", "0"])
    end
  end
end
