defmodule AllbertAssist.Channels.Discord.Client do
  @moduledoc false

  alias AllbertAssist.External.HttpPolicy
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Settings.Secrets

  @base_url "https://discord.com/api/v10"
  @default_max_response_bytes 1_048_576

  def gateway_bot(token_ref, opts \\ []) do
    case client_mode(opts) do
      :stub -> stub_gateway_bot(token_ref, opts)
      :real -> request(:get, token_ref, "/gateway/bot", [], opts)
    end
  end

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

  def update_message(token_ref, channel_id, message_id, payload, opts \\ []) do
    case client_mode(opts) do
      :stub -> stub_update_message(channel_id, message_id, payload, opts)

      :real ->
        request(
          :patch,
          token_ref,
          "/channels/#{URI.encode(to_string(channel_id))}/messages/#{URI.encode(to_string(message_id))}",
          [json: payload],
          opts
        )
    end
  end

  def interaction_callback(interaction_id, interaction_token, payload, opts \\ []) do
    case client_mode(opts) do
      :stub ->
        stub_interaction_callback(interaction_id, interaction_token, payload, opts)

      :real ->
        request_interaction_callback(interaction_id, interaction_token, payload, opts)
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

  def update_message_request(token_ref, channel_id, message_id, payload) do
    build_request(
      :patch,
      token_ref,
      "/channels/#{URI.encode(to_string(channel_id))}/messages/#{URI.encode(to_string(message_id))}",
      json: payload
    )
  end

  def interaction_callback_request(interaction_id, _interaction_token, payload) do
    path = redacted_interaction_callback_path(interaction_id)

    %{
      method: :post,
      url: @base_url <> path,
      path: path,
      headers: [],
      redacted_headers: [],
      body: payload
    }
  end

  def users_me_request(token_ref), do: build_request(:get, token_ref, "/users/@me", [])

  def gateway_bot_request(token_ref), do: build_request(:get, token_ref, "/gateway/bot", [])

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
         {:ok, token} <- resolve_token(token_ref),
         request <- build_request(method, token_ref, path, request_opts),
         :ok <- validate_policy(request, request_opts, opts) do
      [
        method: method,
        url: request.url,
        headers: [{"authorization", "Bot " <> token}],
        retry: false,
        redirect: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ]
      |> Keyword.merge(request_opts)
      |> Keyword.delete(:max_response_bytes)
      |> Keyword.merge(Keyword.take(opts, [:plug]))
      |> Req.request()
      |> normalize_response()
    end
  end

  defp request_interaction_callback(interaction_id, interaction_token, payload, opts) do
    request_opts = [json: payload]

    with {:ok, path} <- interaction_callback_path(interaction_id, interaction_token),
         request <- interaction_callback_request(interaction_id, interaction_token, payload),
         :ok <- validate_policy(request, request_opts, opts) do
      [
        method: :post,
        url: @base_url <> path,
        headers: [],
        retry: false,
        redirect: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ]
      |> Keyword.merge(request_opts)
      |> Keyword.delete(:max_response_bytes)
      |> Keyword.merge(Keyword.take(opts, [:plug]))
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
      allowed_methods: ["GET", "POST", "PATCH"]
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

  defp stub_gateway_bot(token_ref, opts) do
    with :ok <- validate_token_ref(token_ref) do
      case stub_result(opts) do
        :success ->
          {:ok,
           %{
             "url" => Keyword.get(opts, :gateway_url, "wss://gateway.discord.gg"),
             "session_start_limit" => %{
               "total" => 1000,
               "remaining" => 1000,
               "reset_after" => 0,
               "max_concurrency" => 1
             }
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

  defp stub_update_message(channel_id, message_id, payload, opts) do
    case stub_result(opts) do
      :success ->
        maybe_capture(
          opts,
          {:discord_update_message, to_string(channel_id), to_string(message_id), payload}
        )

        {:ok,
         %{
           "id" => to_string(message_id),
           "channel_id" => to_string(channel_id),
           "content" => Map.get(payload, :content, Map.get(payload, "content", ""))
         }}

      :unauthorized ->
        {:error, {:discord_error, 401, %{message: "Unauthorized"}}}

      :unavailable ->
        {:error, {:transport_error, :econnrefused}}
    end
  end

  defp stub_interaction_callback(interaction_id, interaction_token, payload, opts) do
    with {:ok, interaction_id} <- required_segment(interaction_id, :interaction_id),
         {:ok, _interaction_token} <- required_segment(interaction_token, :interaction_token) do
      case stub_result(opts) do
        :success ->
          maybe_capture(opts, {:discord_interaction_callback, interaction_id, payload})

          {:ok,
           %{"id" => interaction_id, "type" => Map.get(payload, :type, Map.get(payload, "type"))}}

        :unauthorized ->
          {:error, {:discord_error, 401, %{message: "Unauthorized"}}}

        :unavailable ->
          {:error, {:transport_error, :econnrefused}}
      end
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

  defp interaction_callback_path(interaction_id, interaction_token) do
    with {:ok, interaction_id} <- required_segment(interaction_id, :interaction_id),
         {:ok, interaction_token} <- required_segment(interaction_token, :interaction_token) do
      {:ok,
       "/interactions/#{URI.encode_www_form(interaction_id)}/#{URI.encode_www_form(interaction_token)}/callback"}
    end
  end

  defp redacted_interaction_callback_path(interaction_id) do
    interaction_id =
      interaction_id
      |> to_string()
      |> URI.encode_www_form()

    "/interactions/#{interaction_id}/[REDACTED]/callback"
  end

  defp required_segment(value, _field) when value in [nil, ""],
    do: {:error, :invalid_discord_interaction}

  defp required_segment(value, _field) do
    value = value |> to_string() |> String.trim()

    if value == "" do
      {:error, :invalid_discord_interaction}
    else
      {:ok, value}
    end
  end

  defp resolve_token(token_ref) do
    case Secrets.get_secret(token_ref) do
      {:ok, token} when is_binary(token) ->
        token = String.trim(token)

        if token == "" do
          {:error, :missing_discord_token}
        else
          {:ok, token}
        end

      {:error, reason} ->
        {:error, {:discord_token_unavailable, reason}}
    end
  end

  defp maybe_capture(opts, message) do
    case Keyword.get(opts, :capture_to) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end

  defp redact_body(body) when is_map(body), do: Map.drop(body, ["token", "authorization"])
  defp redact_body(_body), do: %{}
end
