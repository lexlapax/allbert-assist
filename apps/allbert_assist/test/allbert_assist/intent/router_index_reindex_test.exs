defmodule AllbertAssist.Intent.Router.IndexReindexTest do
  @moduledoc "v0.54 M9.3b — Index reindex-on-signal (debounced) logic."
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Intent.Router.Embedder.FakeEmbedder
  alias AllbertAssist.Intent.Router.Index

  setup do
    prev = Application.get_env(:allbert_assist, :intent_router_embedder)
    Application.put_env(:allbert_assist, :intent_router_embedder, FakeEmbedder)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:allbert_assist, :intent_router_embedder, prev),
        else: Application.delete_env(:allbert_assist, :intent_router_embedder)
    end)

    {:ok, pid} =
      Index.start_link(name: :"index_reindex_#{System.unique_integer([:positive])}")

    %{pid: pid}
  end

  test "an action-set signal marks the index stale and schedules a debounced rebuild", %{pid: pid} do
    %{status: :built} = Index.rebuild(pid)

    send(pid, {:signal, %{type: "allbert.dynamic_codegen.registered"}})

    state = Index.state(pid)
    assert state.status == :not_built, "a registration signal must mark the index stale"
    assert state.rebuild_timer != nil, "a debounced rebuild must be scheduled"
  end

  test "a debounce burst coalesces into a single pending rebuild", %{pid: pid} do
    %{status: :built} = Index.rebuild(pid)

    send(pid, {:signal, %{type: "allbert.dynamic_codegen.registered"}})
    timer1 = Index.state(pid).rebuild_timer
    send(pid, {:signal, %{type: "allbert.dynamic_codegen.rolled_back"}})
    timer2 = Index.state(pid).rebuild_timer

    assert timer1 != nil and timer2 != nil
    refute timer1 == timer2, "the second signal reschedules (coalesces) the rebuild"
  end
end
