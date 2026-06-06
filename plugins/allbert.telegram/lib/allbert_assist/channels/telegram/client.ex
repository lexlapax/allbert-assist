defmodule AllbertAssist.Channels.Telegram.Client do
  @moduledoc false

  @base_url "https://api.telegram.org"

  def get_updates(token, offset, timeout_seconds, opts \\ []) do
    request(
      :get,
      token,
      "getUpdates",
      [
        params: %{
          "offset" => offset,
          "timeout" => timeout_seconds,
          "allowed_updates" => Jason.encode!(["message", "callback_query"])
        },
        receive_timeout: (timeout_seconds + 5) * 1000
      ],
      opts
    )
  end

  def send_message(token, chat_id, text, opts \\ []) do
    request(
      :post,
      token,
      "sendMessage",
      [
        json:
          %{
            "chat_id" => chat_id,
            "text" => text
          }
          |> maybe_put("reply_markup", Keyword.get(opts, :reply_markup)),
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ],
      opts
    )
  end

  def answer_callback_query(token, callback_query_id, text \\ nil, opts \\ []) do
    request(
      :post,
      token,
      "answerCallbackQuery",
      [
        json:
          %{
            "callback_query_id" => callback_query_id
          }
          |> maybe_put("text", text),
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ],
      opts
    )
    |> case do
      {:ok, true} -> {:ok, true}
      {:ok, %{"result" => true}} -> {:ok, true}
      other -> other
    end
  end

  def get_file(token, file_id, opts \\ []) do
    request(
      :post,
      token,
      "getFile",
      [
        json: %{"file_id" => file_id},
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ],
      opts
    )
  end

  def download_file(token, file_path, opts \\ []) do
    [
      method: :get,
      url: file_url(token, file_path),
      retry: false,
      redirect: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
    ]
    |> maybe_put(:plug, Keyword.get(opts, :plug))
    |> Req.request()
    |> normalize_file_response()
  end

  defp request(method, token, method_name, request_opts, opts) do
    [
      method: method,
      url: url(token, method_name),
      retry: false,
      redirect: false
    ]
    |> Keyword.merge(request_opts)
    |> maybe_put(:plug, Keyword.get(opts, :plug))
    |> Req.request()
    |> normalize_response()
  end

  defp normalize_response({:ok, %{status: status, body: %{"ok" => true, "result" => result}}})
       when status in 200..299 do
    {:ok, result}
  end

  defp normalize_response({:ok, %{status: status, body: body}}) do
    {:error, {:telegram_error, status, redact_body(body)}}
  end

  defp normalize_response({:error, %Req.TransportError{} = error}) do
    {:error, {:transport_error, error.reason}}
  end

  defp normalize_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp normalize_file_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp normalize_file_response({:ok, %{status: status, body: body}}) do
    {:error, {:telegram_file_error, status, redact_body(body)}}
  end

  defp normalize_file_response({:error, %Req.TransportError{} = error}) do
    {:error, {:transport_error, error.reason}}
  end

  defp normalize_file_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp url(token, method_name), do: "#{@base_url}/bot#{URI.encode(token)}/#{method_name}"

  defp file_url(token, file_path) do
    "#{@base_url}/file/bot#{URI.encode(token)}/#{encode_file_path(file_path)}"
  end

  defp encode_file_path(file_path) do
    file_path
    |> to_string()
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &URI.encode/1)
  end

  defp redact_body(body) when is_map(body) do
    Map.drop(body, ["token", "password", "api_key", "authorization"])
  end

  defp redact_body(_body), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
