defmodule AllbertAssist.Channels.Discord.Client do
  @moduledoc false

  alias AllbertAssist.External.HttpPolicy
  alias AllbertAssist.External.RequestSpec

  @base_url "https://discord.com/api/v10"
  @default_max_response_bytes 1_048_576

  def users_me(token_ref, opts \\ []) do
    case client_mode(opts) do
      :stub -> stub_users_me(token_ref, opts)
      :real -> request(:get, token_ref, "/users/@me", [], opts)
    end
  end

  def create_message(token_ref, channel_id, payload, opts \\ []) do
    case client_mode(opts) do
      :stub ->
        stub_create_message(channel_id, payload, opts)

      :real ->
        request(
          :post,
          token_ref,
          "/channels/#{URI.encode(to_string(channel_id))}/messages",
          [json: payload],
          opts
        )
    end
  end

  def create_message_request(token_ref, channel_id, payload) do
    build_request(
      :post,
      token_ref,
      "/channels/#{URI.encode(to_string(channel_id))}/messages",
      json: payload
    )
  end

  def users_me_request(token_ref), do: build_request(:get, token_ref, "/users/@me", [])

  def start_thread_from_message_request(token_ref, channel_id, message_id, payload) do
    build_request(
      :post,
      token_ref,
      "/channels/#{URI.encode(to_string(channel_id))}/messages/#{URI.encode(to_string(message_id))}/threads",
      json: payload
    )
  end

  defp request(method, token_ref, path, request_opts, opts) do
    with :ok <- validate_token_ref(token_ref),
         request <- build_request(method, token_ref, path, request_opts),
         :ok <- validate_policy(request, request_opts, opts) do
      [
        method: method,
        url: request.url,
        headers: [{"authorization", "Bot " <> token_ref}],
        retry: false,
        redirect: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ]
      |> Keyword.merge(request_opts)
      |> Keyword.delete(:max_response_bytes)
      |> Req.request()
      |> normalize_response()
    end
  end

  defp build_request(method, token_ref, path, request_opts) do
    %{
      method: method,
      url: @base_url <> path,
      path: path,
      headers: [{"authorization", "Bot " <> to_string(token_ref)}],
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
      profile: "discord_gateway",
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
      allowed_hosts: ["discord.com"],
      blocked_hosts: [],
      allowed_paths: ["/api/v10"],
      allowed_methods: ["GET", "POST"]
    }

    case HttpPolicy.validate(spec) do
      :ok -> :ok
      {:error, reason} -> {:error, {:discord_http_policy_denied, reason}}
    end
  end

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
    do: {:error, {:discord_error, status, redact_body(body)}}

  defp normalize_response({:error, %Req.TransportError{} = error}),
    do: {:error, {:transport_error, error.reason}}

  defp normalize_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp stub_users_me(token_ref, opts) do
    with :ok <- validate_token_ref(token_ref) do
      case stub_result(opts) do
        :success ->
          {:ok,
           %{
             "id" => "000000000000000052",
             "username" => "allbert-fixture",
             "bot" => true
           }}

        :unauthorized ->
          {:error, {:discord_error, 401, %{message: "Unauthorized"}}}

        :unavailable ->
          {:error, {:transport_error, :econnrefused}}
      end
    end
  end

  defp stub_create_message(channel_id, payload, opts) do
    case stub_result(opts) do
      :success ->
        maybe_capture(opts, {:discord_create_message, to_string(channel_id), payload})

        {:ok,
         %{
           "id" => "bot_" <> Ecto.UUID.generate(),
           "channel_id" => to_string(channel_id),
           "content" => Map.get(payload, :content, Map.get(payload, "content", "")),
           "components" => Map.get(payload, :components, Map.get(payload, "components", [])),
           "message_reference" =>
             Map.get(payload, :message_reference, Map.get(payload, "message_reference"))
         }}

      :unauthorized ->
        {:error, {:discord_error, 401, %{message: "Unauthorized"}}}

      :unavailable ->
        {:error, {:transport_error, :econnrefused}}
    end
  end

  defp client_mode(opts) do
    Keyword.get(opts, :mode, Application.get_env(:allbert_assist, :discord_client_mode, :stub))
  end

  defp stub_result(opts) do
    Keyword.get(
      opts,
      :stub_result,
      Application.get_env(:allbert_assist, :discord_client_stub_result, :success)
    )
  end

  defp validate_token_ref(token_ref) when is_binary(token_ref) do
    if Regex.match?(~r/^secret:\/\/channels\/discord\/[A-Za-z0-9_-]+$/, token_ref) do
      :ok
    else
      {:error, :invalid_discord_token_ref}
    end
  end

  defp validate_token_ref(_token_ref), do: {:error, :invalid_discord_token_ref}

  defp maybe_capture(opts, message) do
    case Keyword.get(opts, :capture_to) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end

  defp redact_body(body) when is_map(body), do: Map.drop(body, ["token", "authorization"])
  defp redact_body(_body), do: %{}
end
