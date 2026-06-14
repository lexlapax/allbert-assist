defmodule AllbertAssistWeb.Plugs.PublicProtocolBodyReader do
  @moduledoc """
  Settings-bound body reader for public protocol parser reads.
  """

  alias AllbertAssist.PublicProtocol.HttpIngress

  def read_body(conn, opts) do
    case conn.private[:allbert_public_protocol_raw_body] do
      raw_body when is_binary(raw_body) ->
        {:ok, raw_body, conn}

      _missing ->
        conn
        |> Plug.Conn.read_body(public_protocol_opts(conn, opts))
        |> maybe_cache_raw_body()
    end
  end

  defp public_protocol_opts(conn, opts) do
    if HttpIngress.public_path?(conn.request_path) do
      Keyword.put(opts, :length, HttpIngress.max_body_bytes())
    else
      opts
    end
  end

  defp maybe_cache_raw_body({:ok, raw_body, conn}) do
    if HttpIngress.webhook_path?(conn.request_path) do
      {:ok, raw_body, Plug.Conn.put_private(conn, :allbert_public_protocol_raw_body, raw_body)}
    else
      {:ok, raw_body, conn}
    end
  end

  defp maybe_cache_raw_body(other), do: other
end
