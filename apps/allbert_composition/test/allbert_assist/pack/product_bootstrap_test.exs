defmodule AllbertAssist.Pack.ProductBootstrapTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Pack.ProductBootstrap

  test "public bootstrap uses the production seam map and returns the current epoch" do
    assert {:ok, %{barrier_pid: barrier_pid, snapshot_digest: snapshot_digest}} =
             ProductBootstrap.ensure_ready([])

    assert is_pid(barrier_pid)
    assert is_binary(snapshot_digest)
  end

  test "returns only a freshly rechecked ready epoch" do
    epoch = %{barrier_pid: self(), snapshot_digest: String.duplicate("a", 64)}

    assert {:ok, ^epoch} =
             ProductBootstrap.ensure_ready_for_test(
               application_starter: fn :allbert_composition -> {:ok, [:allbert_composition]} end,
               readiness_await: fn _deadline -> {:ok, epoch} end,
               readiness_status: fn _timeout -> {:ok, Map.put(epoch, :phase, :ready)} end,
               application_stopper: fn app ->
                 flunk("must not stop #{inspect(app)} on success")
               end
             )
  end

  test "application start failure is redacted and does not stop pre-existing applications" do
    assert {:error, :application_start_failed} =
             ProductBootstrap.ensure_ready_for_test(
               application_starter: fn :allbert_composition ->
                 {:error, {:allbert_assist, :boom}}
               end,
               application_stopper: fn app -> flunk("must not stop #{inspect(app)}") end
             )
  end

  test "readiness failure stops exactly newly-started applications in reverse order" do
    parent = self()

    assert {:error, :readiness_failed} =
             ProductBootstrap.ensure_ready_for_test(
               application_starter: fn :allbert_composition ->
                 {:ok, [:req, :allbert_composition]}
               end,
               readiness_await: fn _deadline -> {:error, :unavailable} end,
               application_stopper: fn app ->
                 send(parent, {:stopped, app})
                 :ok
               end
             )

    assert_receive {:stopped, :allbert_composition}
    assert_receive {:stopped, :req}
  end

  test "a lost final status tears down newly-started applications" do
    parent = self()
    epoch = %{barrier_pid: self(), snapshot_digest: String.duplicate("b", 64)}

    assert {:error, :readiness_lost} =
             ProductBootstrap.ensure_ready_for_test(
               application_starter: fn :allbert_composition -> {:ok, [:allbert_composition]} end,
               readiness_await: fn _deadline -> {:ok, epoch} end,
               readiness_status: fn _timeout -> {:error, :unavailable} end,
               application_stopper: fn app ->
                 send(parent, {:stopped, app})
                 :ok
               end
             )

    assert_receive {:stopped, :allbert_composition}
  end
end
