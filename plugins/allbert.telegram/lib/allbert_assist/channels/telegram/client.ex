defmodule AllbertAssist.Channels.Telegram.Client do
  @moduledoc false

  alias AllbertAssist.External.HttpPolicy
  alias AllbertAssist.External.RequestSpec

  @base_url "https://api.telegram.org"
  @default_max_response_bytes 1_048_576

  def get_me(token, opts \\ []) do
    case client_mode(opts) do
      :stub ->
        stub_get_me(token, opts)

      :real ->
        request(
          :get,
          token,
          "getMe",
          [receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)],
          opts
        )
    end
  end

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
          |> maybe_put("reply_markup", Keyword.get(opts, :reply_markup))
          |> maybe_put("reply_parameters", reply_parameters(opts))
          |> maybe_put("message_thread_id", Keyword.get(opts, :message_thread_id)),
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ],
      opts
    )
  end

  defp reply_parameters(opts) do
    case Keyword.get(opts, :reply_to_message_id) do
      nil -> nil
      "" -> nil
      message_id -> %{"message_id" => message_id}
    end
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
    max_response_bytes = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)
    url = file_url(token, file_path)
    request_opts = [receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)]

    with :ok <- validate_policy(:get, url, request_opts, max_response_bytes) do
      [
        method: :get,
        url: url,
        retry: false,
        redirect: false,
        decode_body: false,
        receive_timeout: Keyword.get(request_opts, :receive_timeout),
        into: capped_body(max_response_bytes)
      ]
      |> maybe_put(:plug, Keyword.get(opts, :plug))
      |> Req.request()
      |> normalize_file_response(max_response_bytes)
    end
  end

  defp request(method, token, method_name, request_opts, opts) do
    {url, request_opts} =
      token
      |> url(method_name)
      |> apply_query_params(request_opts)

    max_response_bytes = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

    with :ok <- validate_policy(method, url, request_opts, max_response_bytes) do
      request_opts =
        request_opts
        |> Keyword.delete(:params)
        |> Keyword.delete(:max_response_bytes)

      [
        method: method,
        url: url,
        retry: false,
        redirect: false
      ]
      |> Keyword.merge(request_opts)
      |> maybe_put(:plug, Keyword.get(opts, :plug))
      |> Req.request()
      |> normalize_response()
    end
  end

  defp validate_policy(method, url, request_opts, max_response_bytes) do
    uri = URI.parse(url)

    spec = %RequestSpec{
      method: method |> Atom.to_string() |> String.upcase(),
      url: URI.to_string(uri),
      uri: uri,
      profile: "telegram_bot_api",
      host: String.downcase(uri.host || ""),
      path: uri.path || "/",
      query: uri.query,
      headers: [],
      body: request_body(request_opts),
      body_summary: body_summary(request_opts),
      timeout_ms: Keyword.get(request_opts, :receive_timeout, 10_000),
      max_response_bytes: max_response_bytes,
      allow_redirects?: false,
      max_redirects: 0,
      retry_policy: "none",
      redact_request_headers: ["authorization", "cookie", "x-api-key"],
      redact_response_headers: ["set-cookie", "authorization"],
      source_text: nil,
      enabled?: true,
      profile_enabled?: true,
      allowed_hosts: ["api.telegram.org"],
      blocked_hosts: [],
      allowed_paths: ["/bot", "/file/bot"],
      allowed_methods: ["GET", "POST"]
    }

    case HttpPolicy.validate(spec) do
      :ok -> :ok
      {:error, reason} -> {:error, {:telegram_http_policy_denied, reason}}
    end
  end

  defp apply_query_params(url, request_opts) do
    case Keyword.pop(request_opts, :params) do
      {nil, request_opts} ->
        {url, request_opts}

      {params, request_opts} ->
        uri = URI.parse(url)
        query = params |> URI.encode_query() |> merge_query(uri.query)
        {URI.to_string(%{uri | query: query}), request_opts}
    end
  end

  defp merge_query(query, nil), do: query
  defp merge_query(query, ""), do: query
  defp merge_query(query, existing), do: "#{existing}&#{query}"

  defp request_body(request_opts) do
    case Keyword.get(request_opts, :json) do
      nil -> Keyword.get(request_opts, :body)
      json -> Jason.encode!(json)
    end
  end

  defp body_summary(request_opts) do
    case request_body(request_opts) do
      nil -> %{type: "none", bytes: 0}
      body when is_binary(body) -> %{type: body_type(request_opts), bytes: byte_size(body)}
    end
  end

  defp body_type(request_opts) do
    if Keyword.has_key?(request_opts, :json), do: "json", else: "raw"
  end

  defp capped_body(max_response_bytes) do
    fn {:data, data}, {req, resp} ->
      body = (resp.body || "") <> data
      action = if byte_size(body) > max_response_bytes, do: :halt, else: :cont
      {action, {req, %{resp | body: body}}}
    end
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

  defp normalize_file_response({:ok, %{status: status, body: body}}, max_response_bytes)
       when status in 200..299 and is_binary(body) do
    if byte_size(body) <= max_response_bytes do
      {:ok, body}
    else
      {:error, {:telegram_file_too_large, byte_size(body), max_response_bytes}}
    end
  end

  defp normalize_file_response({:ok, %{status: status, body: body}}, _max_response_bytes) do
    {:error, {:telegram_file_error, status, redact_body(body)}}
  end

  defp normalize_file_response({:error, %Req.TransportError{} = error}, _max_response_bytes) do
    {:error, {:transport_error, error.reason}}
  end

  defp normalize_file_response({:error, reason}, _max_response_bytes),
    do: {:error, {:transport_error, reason}}

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

  defp stub_get_me(token, opts) do
    with {:ok, _token} <- validate_non_empty_token(token) do
      case stub_result(opts) do
        :success ->
          {:ok,
           %{
             "id" => 52_000_000,
             "is_bot" => true,
             "first_name" => "Allbert Fixture",
             "username" => "allbert_fixture_bot"
           }}

        :unauthorized ->
          {:error, {:telegram_error, 401, %{"description" => "Unauthorized"}}}

        :unavailable ->
          {:error, {:transport_error, :econnrefused}}
      end
    end
  end

  defp validate_non_empty_token(token) when is_binary(token) do
    token = String.trim(token)
    if token == "", do: {:error, :missing_telegram_token}, else: {:ok, token}
  end

  defp validate_non_empty_token(_token), do: {:error, :missing_telegram_token}

  defp client_mode(opts) do
    Keyword.get(opts, :mode, Application.get_env(:allbert_assist, :telegram_client_mode, :real))
  end

  defp stub_result(opts) do
    Keyword.get(
      opts,
      :stub_result,
      Application.get_env(:allbert_assist, :telegram_client_stub_result, :success)
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
