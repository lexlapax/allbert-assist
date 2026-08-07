defmodule AllbertAssistWeb.PackReadiness.HTTPGate do
  @moduledoc false

  import Plug.Conn

  @retry_after "1"

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/health"} = conn, _opts), do: conn

  def call(conn, opts) do
    observer = Keyword.get(opts, :observer, AllbertAssistWeb.PackReadiness)

    case observer.admit() do
      {:ok, epoch} ->
        conn
        |> put_private(:allbert_pack_epoch, epoch)
        |> assign(:allbert_pack_epoch, epoch)
        |> register_before_send(&validate_response_commit(&1, observer, epoch))

      {:error, :product_not_ready} ->
        unavailable(conn)
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

  defp validate_response_commit(conn, observer, epoch) do
    case observer.validate(epoch) do
      :ok -> conn
      {:error, _reason} -> freeze_unavailable_response(conn)
    end
  end

  defp freeze_unavailable_response(conn) do
    conn
    |> put_status(503)
    |> delete_resp_header("content-length")
    |> delete_resp_header("content-encoding")
    |> delete_resp_header("transfer-encoding")
    |> put_resp_header("retry-after", @retry_after)
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type(content_type(conn))
    |> Map.put(:resp_body, body(conn))
  end
end
