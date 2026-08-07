defmodule AllbertAssistWeb.PackReadiness.HTTPGateTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AllbertAssistWeb.PackReadiness.HTTPGate

  defmodule ClosedObserver do
    def admit, do: {:error, :product_not_ready}
  end

  defmodule OpenObserver do
    def admit, do: {:ok, %{barrier_pid: self(), snapshot_digest: String.duplicate("a", 64)}}
    def validate(_epoch), do: :ok
  end

  defmodule SameDigestReplacementObserver do
    @digest String.duplicate("r", 64)

    def admit do
      {:ok, %{barrier_pid: self(), snapshot_digest: @digest}}
    end

    def validate(%{barrier_pid: e1_pid, snapshot_digest: @digest}) do
      e2_pid = spawn(fn -> :ok end)

      if e1_pid == e2_pid do
        :ok
      else
        {:error, :stale_epoch}
      end
    end
  end

  test "closed product returns the frozen generic 503 before parser work" do
    conn = conn(:post, "/workspace", "unparsed") |> HTTPGate.call(observer: ClosedObserver)

    assert conn.halted
    assert conn.status == 503
    assert conn.resp_body == "Allbert product is not ready.\n"
    assert get_resp_header(conn, "retry-after") == ["1"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "closed product preserves protocol-specific bodies" do
    assert HTTPGate.call(conn(:post, "/mcp", ""), observer: ClosedObserver).resp_body ==
             ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"product_not_ready"}})

    assert HTTPGate.call(conn(:get, "/v1/models", ""), observer: ClosedObserver).resp_body ==
             ~s({"error":{"message":"Allbert product is not ready.","type":"service_unavailable","code":"product_not_ready"}})

    assert HTTPGate.call(conn(:post, "/webhooks/whatsapp/phone", ""), observer: ClosedObserver).resp_body ==
             ~s({"error":{"code":"product_not_ready","message":"Allbert product is not ready."}})
  end

  test "health remains available while product admission is closed" do
    conn = conn(:get, "/health", "") |> HTTPGate.call(observer: ClosedObserver)
    refute conn.halted
  end

  test "admitted requests carry one exact observer epoch privately and in root assigns" do
    conn = conn(:get, "/v1/models", "") |> HTTPGate.call(observer: OpenObserver)

    assert %{barrier_pid: barrier_pid, snapshot_digest: digest} =
             epoch =
             conn.private[:allbert_pack_epoch]

    assert barrier_pid == self()
    assert digest == String.duplicate("a", 64)
    assert conn.assigns.allbert_pack_epoch == epoch
  end

  test "same-digest E2 before root response commit freezes ordinary HTML as the canonical 503" do
    conn =
      conn(:get, "/workspace", "")
      |> HTTPGate.call(observer: SameDigestReplacementObserver)
      |> put_resp_content_type("text/html")
      |> put_resp_header("content-length", "999")
      |> put_resp_header("content-encoding", "gzip")
      |> send_resp(200, "<html><body>stale default theme</body></html>")

    assert conn.status == 503
    assert conn.resp_body == "Allbert product is not ready.\n"
    assert get_resp_header(conn, "retry-after") == ["1"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "content-length") == []
    assert get_resp_header(conn, "content-encoding") == []
    refute conn.resp_body =~ "stale default theme"
  end
end
