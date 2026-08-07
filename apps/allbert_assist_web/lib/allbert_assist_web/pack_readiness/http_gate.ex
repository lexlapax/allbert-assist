defmodule AllbertAssistWeb.PackReadiness.HTTPGate do
  @moduledoc false

  import Plug.Conn

  @retry_after "1"

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/health"} = conn, _opts), do: conn

  def call(conn, opts) do
    observer = Keyword.get(opts, :observer, AllbertAssistWeb.PackReadiness)

    case observer.admit() do
      {:ok, epoch} -> put_private(conn, :allbert_pack_epoch, epoch)
      {:error, :product_not_ready} -> unavailable(conn)
    end
  end

  @doc false
  @spec unavailable(Plug.Conn.t()) :: Plug.Conn.t()
  def unavailable(conn) do
    conn
    |> put_resp_header("retry-after", @retry_after)
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type(content_type(conn))
    |> send_resp(503, body(conn))
    |> halt()
  end

  defp content_type(%{request_path: "/mcp"}), do: "application/json"
  defp content_type(%{request_path: "/v1/" <> _rest}), do: "application/json"
  defp content_type(%{request_path: "/webhooks/whatsapp/" <> _rest}), do: "application/json"
  defp content_type(_conn), do: "text/plain"

  defp body(%{request_path: "/mcp"}),
    do: ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"product_not_ready"}})

  defp body(%{request_path: "/v1/" <> _rest}),
    do:
      ~s({"error":{"message":"Allbert product is not ready.","type":"service_unavailable","code":"product_not_ready"}})

  defp body(%{request_path: "/webhooks/whatsapp/" <> _rest}),
    do: ~s({"error":{"code":"product_not_ready","message":"Allbert product is not ready."}})

  defp body(_conn), do: "Allbert product is not ready.\n"
end
