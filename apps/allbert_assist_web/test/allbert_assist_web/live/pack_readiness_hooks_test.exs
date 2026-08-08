defmodule AllbertAssistWeb.PackReadinessHooksTest do
  use ExUnit.Case, async: false

  @moduletag :liveview_serial

  import Plug.Conn
  import Plug.Test

  alias AllbertAssistWeb.Live.SharedShellHooks

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

  test "a connected mount carrying paused E1 halts to health after readiness reaches E2" do
    assert {:ok, e2} = AllbertAssistWeb.PackReadiness.admit()
    e1 = %{e2 | snapshot_digest: String.duplicate("1", 64)}

    socket = %Phoenix.LiveView.Socket{
      endpoint: AllbertAssistWeb.Endpoint,
      transport_pid: self(),
      assigns: %{__changed__: %{}},
      private: %{connect_info: %{allbert_pack_epoch: e1}, live_temp: %{}}
    }

    assert {:halt, redirected} =
             AllbertAssistWeb.PackReadiness.on_mount(:live_session, %{}, %{}, socket)

    assert redirected.redirected == {:redirect, %{status: 302, to: "/health"}}
    refute redirected.assigns[:allbert_pack_epoch]
  end

  test "the shared shell revalidates its connected socket E1 instead of compatibility-admitting E2" do
    assert {:ok, e2} = AllbertAssistWeb.PackReadiness.admit()
    e1 = %{e2 | snapshot_digest: String.duplicate("1", 64)}

    socket = %Phoenix.LiveView.Socket{
      endpoint: AllbertAssistWeb.Endpoint,
      transport_pid: self(),
      assigns: %{__changed__: %{}, allbert_pack_epoch: e1},
      private: %{live_temp: %{}}
    }

    assert {:halt, redirected} = SharedShellHooks.on_mount(:shell_chrome, %{}, %{}, socket)
    assert redirected.redirected == {:redirect, %{status: 302, to: "/health"}}
  end

  test "non-mount readiness hooks halt without adding a redirect" do
    socket = %Phoenix.LiveView.Socket{assigns: %{allbert_pack_epoch: :stale}}

    assert {:halt, halted} = AllbertAssistWeb.PackReadiness.lifecycle_result(socket)
    refute halted.redirected
  end
end
