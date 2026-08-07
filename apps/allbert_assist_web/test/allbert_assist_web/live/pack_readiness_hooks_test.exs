defmodule AllbertAssistWeb.PackReadinessHooksTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  test "copies only the admitted epoch into the signed LiveView session payload" do
    barrier = self()
    epoch = %{barrier_pid: barrier, snapshot_digest: String.duplicate("a", 64)}

    assert AllbertAssistWeb.PackReadiness.live_session(
             put_private(conn(:get, "/workspace"), :allbert_pack_epoch, epoch)
           ) == %{"allbert_pack_epoch" => epoch}
  end

  test "does not manufacture a session token without HTTP admission" do
    assert AllbertAssistWeb.PackReadiness.live_session(conn(:get, "/workspace")) == %{}
  end
end
