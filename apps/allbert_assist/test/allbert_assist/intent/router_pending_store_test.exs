defmodule AllbertAssist.Intent.Router.PendingStoreTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Intent.PendingClarification
  alias AllbertAssist.Intent.Router.PendingStore

  defp pending(user, thread, opts \\ []) do
    now = ~U[2026-06-16 00:00:00Z]

    %PendingClarification{
      user_id: user,
      thread_id: thread,
      options: Keyword.get(opts, :options, [%{kind: :action, id: "create_note", label: "Create note"}]),
      question: "Q?",
      created_at: now,
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 60_000, :millisecond))
    }
  end

  test "put then take returns and removes the entry" do
    u = "u-#{System.unique_integer([:positive])}"
    :ok = PendingStore.put(pending(u, "t1"))
    assert {:ok, %PendingClarification{user_id: ^u}} = PendingStore.take(u, "t1")
    # second take is empty (removed)
    assert :none = PendingStore.take(u, "t1")
  end

  test "an expired entry is dropped on take" do
    u = "u-#{System.unique_integer([:positive])}"
    past = DateTime.add(DateTime.utc_now(), -1000, :millisecond)
    :ok = PendingStore.put(pending(u, "t1", expires_at: past))
    assert :none = PendingStore.take(u, "t1")
  end

  test "entries are isolated by {user_id, thread_id}" do
    u1 = "u-#{System.unique_integer([:positive])}"
    u2 = "u-#{System.unique_integer([:positive])}"
    :ok = PendingStore.put(pending(u1, "t1"))

    assert :none = PendingStore.take(u2, "t1")
    assert :none = PendingStore.take(u1, "t2")
    assert {:ok, _} = PendingStore.take(u1, "t1")
  end
end
