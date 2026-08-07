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

  test "admitted requests carry the exact observer epoch privately" do
    conn = conn(:get, "/v1/models", "") |> HTTPGate.call(observer: OpenObserver)

    assert %{barrier_pid: barrier_pid, snapshot_digest: digest} =
             conn.private[:allbert_pack_epoch]

    assert barrier_pid == self()
    assert digest == String.duplicate("a", 64)
  end
end
