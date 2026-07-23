defmodule AllbertAssist.Channels.Matrix.Client do
  @moduledoc false

  alias AllbertAssist.External.HttpPolicy
  alias AllbertAssist.External.RequestSpec

  @default_max_response_bytes 1_048_576

  def whoami(homeserver_url, access_token, opts \\ []) do
    request(:get, homeserver_url, access_token, "/account/whoami", [], opts)
  end

  def sync(homeserver_url, access_token, since, timeout_ms, opts \\ []) do
    params =
      %{"timeout" => timeout_ms}
      |> maybe_put("since", since)
      |> maybe_put("filter", Keyword.get(opts, :filter))

    request(:get, homeserver_url, access_token, "/sync", [params: params], opts)
  end

  def send_message(homeserver_url, access_token, room_id, txn_id, content, opts \\ []) do
    request(
      :put,
      homeserver_url,
      access_token,
      "/rooms/#{encode_path(room_id)}/send/m.room.message/#{encode_path(txn_id)}",
      [json: content],
      opts
    )
  end

  def replace_message(
        homeserver_url,
        access_token,
        room_id,
        txn_id,
        event_id,
        body,
        opts \\ []
      ) do
    content = %{
      "msgtype" => "m.text",
      "body" => "* #{body}",
      "m.new_content" => %{"msgtype" => "m.text", "body" => body},
      "m.relates_to" => %{"rel_type" => "m.replace", "event_id" => event_id}
    }

    send_message(homeserver_url, access_token, room_id, txn_id, content, opts)
  end

  def messages(homeserver_url, access_token, room_id, from_token, limit, opts \\ []) do
    params =
      %{"dir" => "b", "limit" => limit}
      |> maybe_put("from", from_token)

    request(
      :get,
      homeserver_url,
      access_token,
      "/rooms/#{encode_path(room_id)}/messages",
      [params: params],
      opts
    )
  end

  def send_message_request(homeserver_url, room_id, txn_id, content) do
    build_request(
      :put,
      homeserver_url,
      "/rooms/#{encode_path(room_id)}/send/m.room.message/#{encode_path(txn_id)}",
      json: content
    )
  end

  def sync_request(homeserver_url, since, timeout_ms, opts \\ []) do
    params =
      %{"timeout" => timeout_ms}
      |> maybe_put("since", since)
      |> maybe_put("filter", Keyword.get(opts, :filter))

    build_request(:get, homeserver_url, "/sync", params: params)
  end

  def whoami_request(homeserver_url),
    do: build_request(:get, homeserver_url, "/account/whoami", [])

  def messages_request(homeserver_url, room_id, from_token, limit) do
    params =
      %{"dir" => "b", "limit" => limit}
      |> maybe_put("from", from_token)

    build_request(:get, homeserver_url, "/rooms/#{encode_path(room_id)}/messages", params: params)
  end

  defp request(method, homeserver_url, access_token, path, request_opts, opts) do
    with {:ok, token} <- validate_access_token(access_token),
         request <- build_request(method, homeserver_url, path, request_opts),
         :ok <- validate_policy(request, request_opts, opts) do
      [
        method: method,
        url: request.url,
        headers: [{"authorization", "Bearer " <> token}],
        retry: false,
        redirect: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ]
      |> Keyword.merge(request_opts)
      |> Keyword.delete(:params)
      |> Keyword.delete(:max_response_bytes)
      |> Keyword.merge(Keyword.take(opts, [:plug]))
      |> Req.request()
      |> normalize_response()
    end
  end

  defp build_request(method, homeserver_url, path, request_opts) do
    base = homeserver_url |> normalize_base_url() |> String.trim_trailing("/")
    url = base <> "/_matrix/client/v3" <> path
    {url, request_opts} = apply_query_params(url, request_opts)

    %{
      method: method,
      url: url,
      path: URI.parse(url).path,
      headers: [{"authorization", "Bearer [REDACTED]"}],
      redacted_headers: [{"authorization", "[REDACTED]"}],
      body: Keyword.get(request_opts, :json)
    }
  end

  defp validate_policy(request, request_opts, opts) do
    uri = URI.parse(request.url)
    max_response_bytes = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

    spec = %RequestSpec{
      method: request.method |> Atom.to_string() |> String.upcase(),
      url: URI.to_string(uri),
      uri: uri,
      profile: "matrix_client_server",
      host: String.downcase(uri.host || ""),
      path: uri.path || "/",
      query: uri.query,
      headers: [],
      body: request_body(request_opts),
      body_summary: body_summary(request_opts),
      timeout_ms: Keyword.get(opts, :receive_timeout, 10_000),
      max_response_bytes: max_response_bytes,
      allow_redirects?: false,
      max_redirects: 0,
      retry_policy: "none",
      redact_request_headers: ["authorization", "cookie", "x-api-key"],
      redact_response_headers: ["set-cookie", "authorization"],
      source_text: nil,
      enabled?: true,
      profile_enabled?: true,
      allowed_hosts: [String.downcase(uri.host || "")],
      blocked_hosts: [],
      allowed_paths: ["/_matrix/client/v3"],
      allowed_methods: ["GET", "PUT"]
    }

    case HttpPolicy.validate(spec) do
      :ok -> :ok
      {:error, reason} -> {:error, {:matrix_http_policy_denied, reason}}
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

  defp normalize_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp normalize_response({:ok, %{status: status, body: body}}),
    do: {:error, {:matrix_error, status, redact_body(body)}}

  defp normalize_response({:error, %Req.TransportError{} = error}),
    do: {:error, {:transport_error, error.reason}}

  defp normalize_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp validate_access_token(token) when is_binary(token) do
    token = String.trim(token)
    if token == "", do: {:error, :missing_matrix_access_token}, else: {:ok, token}
  end

  defp validate_access_token(_token), do: {:error, :missing_matrix_access_token}

  defp normalize_base_url(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> "https://matrix.invalid"
      url -> url
    end
  end

  defp encode_path(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp redact_body(body) when is_map(body) do
    Map.drop(body, ["access_token", "refresh_token", "token", "password"])
  end

  defp redact_body(_body), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
