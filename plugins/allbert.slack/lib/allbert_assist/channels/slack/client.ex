defmodule AllbertAssist.Channels.Slack.Client do
  @moduledoc false

  alias AllbertAssist.External.HttpPolicy
  alias AllbertAssist.External.RequestSpec

  @base_url "https://slack.com/api"
  @default_max_response_bytes 1_048_576

  def auth_test(token_ref, opts \\ []) do
    case client_mode(opts) do
      :stub -> stub_auth_test(token_ref, opts)
      :real -> request(:post, token_ref, "/auth.test", [], opts)
    end
  end

  def chat_post_message(token_ref, payload, opts \\ []) do
    case client_mode(opts) do
      :stub -> stub_chat_post_message(payload, opts)
      :real -> request(:post, token_ref, "/chat.postMessage", [json: payload], opts)
    end
  end

  def auth_test_request(token_ref), do: build_request(:post, token_ref, "/auth.test", [])

  def chat_post_message_request(token_ref, payload) do
    build_request(:post, token_ref, "/chat.postMessage", json: payload)
  end

  def apps_connections_open_request(app_token_ref) do
    build_request(:post, app_token_ref, "/apps.connections.open", [])
  end

  defp request(method, token_ref, path, request_opts, opts) do
    with :ok <- validate_token_ref(token_ref),
         request <- build_request(method, token_ref, path, request_opts),
         :ok <- validate_policy(request, request_opts, opts) do
      [
        method: method,
        url: request.url,
        headers: [{"authorization", "Bearer " <> token_ref}],
        retry: false,
        redirect: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ]
      |> Keyword.merge(request_opts)
      |> Req.request()
      |> normalize_response()
    end
  end

  defp build_request(method, token_ref, path, request_opts) do
    %{
      method: method,
      url: @base_url <> path,
      path: path,
      headers: [{"authorization", "Bearer " <> to_string(token_ref)}],
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
      profile: "slack_socket_mode",
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
      allowed_hosts: ["slack.com"],
      blocked_hosts: [],
      allowed_paths: ["/api"],
      allowed_methods: ["POST"]
    }

    case HttpPolicy.validate(spec) do
      :ok -> :ok
      {:error, reason} -> {:error, {:slack_http_policy_denied, reason}}
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

  defp normalize_response({:ok, %{status: status, body: %{"ok" => true} = body}})
       when status in 200..299,
       do: {:ok, body}

  defp normalize_response({:ok, %{status: status, body: %{"ok" => false} = body}})
       when status in 200..299,
       do: {:error, {:slack_error, Map.get(body, "error", "unknown_error")}}

  defp normalize_response({:ok, %{status: status, body: body}}),
    do: {:error, {:slack_http_error, status, redact_body(body)}}

  defp normalize_response({:error, %Req.TransportError{} = error}),
    do: {:error, {:transport_error, error.reason}}

  defp normalize_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp stub_auth_test(token_ref, opts) do
    with :ok <- validate_token_ref(token_ref) do
      case stub_result(opts) do
        :success ->
          {:ok,
           %{
             "ok" => true,
             "url" => "https://allbert-fixture.slack.com/",
             "team" => "Allbert Fixture",
             "user" => "bot",
             "team_id" => "T0123ABCDE",
             "user_id" => "UALLBERTBOT",
             "bot_id" => "BALLBERTBOT"
           }}

        :unauthorized ->
          {:error, {:slack_error, "invalid_auth"}}

        :unavailable ->
          {:error, {:transport_error, :econnrefused}}
      end
    end
  end

  defp stub_chat_post_message(payload, opts) do
    case stub_result(opts) do
      :success ->
        maybe_capture(opts, {:slack_chat_post_message, payload})

        channel = Map.get(payload, :channel, Map.get(payload, "channel"))
        text = Map.get(payload, :text, Map.get(payload, "text", ""))

        {:ok,
         %{
           "ok" => true,
           "channel" => channel,
           "ts" => simulated_ts(),
           "message" => %{
             "type" => "message",
             "channel" => channel,
             "text" => text,
             "thread_ts" => Map.get(payload, :thread_ts, Map.get(payload, "thread_ts"))
           }
         }}

      :unauthorized ->
        {:error, {:slack_error, "invalid_auth"}}

      :unavailable ->
        {:error, {:transport_error, :econnrefused}}
    end
  end

  defp client_mode(opts) do
    Keyword.get(opts, :mode, Application.get_env(:allbert_assist, :slack_client_mode, :stub))
  end

  defp stub_result(opts) do
    Keyword.get(
      opts,
      :stub_result,
      Application.get_env(:allbert_assist, :slack_client_stub_result, :success)
    )
  end

  defp validate_token_ref(token_ref) when is_binary(token_ref) do
    if Regex.match?(~r/^secret:\/\/channels\/slack\/[A-Za-z0-9_-]+$/, token_ref) do
      :ok
    else
      {:error, :invalid_slack_token_ref}
    end
  end

  defp validate_token_ref(_token_ref), do: {:error, :invalid_slack_token_ref}

  defp maybe_capture(opts, message) do
    case Keyword.get(opts, :capture_to) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end

  defp simulated_ts do
    {mega, seconds, micro} = :os.timestamp()

    Integer.to_string(mega * 1_000_000 + seconds) <>
      "." <> String.pad_leading(to_string(micro), 6, "0")
  end

  defp redact_body(body) when is_map(body), do: Map.drop(body, ["token", "authorization"])
  defp redact_body(_body), do: %{}
end
