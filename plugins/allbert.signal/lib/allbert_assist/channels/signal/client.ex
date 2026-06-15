defmodule AllbertAssist.Channels.Signal.Client do
  @moduledoc false

  alias AllbertAssist.Settings.Secrets

  @default_receive_timeout 10_000

  def json_rpc_request(method, params, id \\ nil) when is_binary(method) and is_map(params) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => id || request_id()
    }
  end

  def send_message(account, recipient, text, opts \\ []) do
    params =
      %{
        "recipient" => [recipient],
        "message" => text
      }
      |> maybe_put_account(account)
      |> maybe_put_quote(opts)

    request("send", params, opts)
  end

  def start_link_request(account, device_name, opts \\ []) do
    params =
      %{
        "account" => account,
        "deviceName" => device_name
      }

    request("startLink", params, opts)
  end

  def list_accounts(opts \\ []), do: request("listAccounts", %{}, opts)

  def health_check(opts \\ []) do
    case request("listAccounts", %{}, opts) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def request(method, params, opts \\ []) do
    rpc = json_rpc_request(method, params, Keyword.get(opts, :id))

    case client_mode(opts) do
      :stub -> stub_request(rpc, opts)
      :loopback_http -> http_request(rpc, opts)
      :socket -> socket_request(rpc, opts)
    end
  end

  defp socket_request(rpc, opts) do
    timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    with {:ok, path} <- socket_path(Keyword.get(opts, :socket_path)),
         {:ok, socket} <-
           :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line], timeout),
         :ok <- :gen_tcp.send(socket, Jason.encode!(rpc) <> "\n"),
         result <- socket_response(socket, rpc["id"], timeout) do
      :gen_tcp.close(socket)
      result
    else
      {:error, reason} -> {:error, {:signal_socket_error, reason}}
    end
  end

  defp socket_path(value) when is_binary(value) and value != "", do: {:ok, value}
  defp socket_path(_value), do: {:error, :missing_signal_socket_path}

  defp socket_response(socket, id, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        with {:ok, decoded} <- Jason.decode(line),
             true <- Map.get(decoded, "id") == id do
          normalize_rpc_response(decoded)
        else
          false -> socket_response(socket, id, timeout)
          {:error, reason} -> {:error, {:invalid_signal_json_rpc, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_request(rpc, opts) do
    with {:ok, base_url} <- loopback_url(Keyword.get(opts, :base_url)),
         {:ok, headers} <- auth_headers(opts) do
      [
        method: :post,
        url: base_url <> "/api/v1/rpc",
        json: rpc,
        headers: headers,
        retry: false,
        redirect: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout)
      ]
      |> Keyword.merge(Keyword.take(opts, [:plug]))
      |> Req.request()
      |> normalize_response()
    end
  end

  defp loopback_url(value) when is_binary(value) and value != "" do
    uri = URI.parse(value)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :signal_control_endpoint_not_http}

      uri.host not in ["127.0.0.1", "localhost", "::1"] ->
        {:error, :signal_control_endpoint_not_loopback}

      true ->
        {:ok, String.trim_trailing(value, "/")}
    end
  end

  defp loopback_url(_value), do: {:error, :missing_signal_loopback_http_base_url}

  defp auth_headers(opts) do
    case Keyword.get(opts, :auth_ref) do
      nil ->
        {:ok, []}

      "" ->
        {:ok, []}

      secret_ref ->
        case Secrets.get_secret(secret_ref) do
          {:ok, token} when is_binary(token) and token != "" ->
            {:ok, [{"authorization", "Bearer " <> token}]}

          _error ->
            {:error, :missing_signal_control_auth}
        end
    end
  end

  defp normalize_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    normalize_rpc_response(body)
  end

  defp normalize_response({:ok, %{status: status, body: body}}),
    do: {:error, {:signal_http_error, status, body}}

  defp normalize_response({:error, %Req.TransportError{} = error}),
    do: {:error, {:transport_error, error.reason}}

  defp normalize_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp normalize_rpc_response(%{"error" => error}), do: {:error, {:signal_rpc_error, error}}
  defp normalize_rpc_response(%{"result" => result}), do: {:ok, result}
  defp normalize_rpc_response(other), do: {:ok, other}

  defp stub_request(%{"method" => "send"} = rpc, _opts) do
    {:ok,
     %{
       "timestamp" => System.system_time(:millisecond),
       "request" => redact_request(rpc)
     }}
  end

  defp stub_request(%{"method" => "startLink"} = rpc, _opts) do
    {:ok,
     %{
       "linkData" => "sgnl://linkdevice?uuid=fixture&pub_key=fixture",
       "request" => redact_request(rpc)
     }}
  end

  defp stub_request(%{"method" => "listAccounts"} = rpc, _opts) do
    {:ok, %{"accounts" => [], "request" => redact_request(rpc)}}
  end

  defp stub_request(rpc, _opts), do: {:ok, %{"request" => redact_request(rpc)}}

  defp redact_request(rpc) do
    params =
      rpc
      |> Map.get("params", %{})
      |> Map.update("message", nil, fn
        nil -> nil
        _message -> "[REDACTED]"
      end)

    Map.put(rpc, "params", params)
  end

  defp maybe_put_account(params, value) when is_binary(value) and value != "",
    do: Map.put(params, "account", value)

  defp maybe_put_account(params, _value), do: params

  defp maybe_put_quote(params, opts) do
    quote_timestamp = Keyword.get(opts, :quote_timestamp_ms)
    quote_author = Keyword.get(opts, :quote_author)

    params
    |> maybe_put("quoteTimestamp", quote_timestamp)
    |> maybe_put("quoteAuthor", quote_author)
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp client_mode(opts), do: Keyword.get(opts, :mode, :socket)

  defp request_id, do: "req_" <> Ecto.UUID.generate()
end
