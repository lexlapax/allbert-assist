defmodule AllbertAssist.PublicProtocol.HttpIngress do
  @moduledoc """
  Shared HTTP ingress helpers for v0.51 public protocol surfaces.

  This module owns auth/rate-limit/header/body-cap decisions at the Allbert
  boundary. Protocol adapters call it before any runtime action work.
  """

  alias AllbertAssist.PublicProtocol.Mcp.ProtocolVersions
  alias AllbertAssist.PublicProtocol.RateLimiter
  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Surfaces.ContextBuilder

  @mcp_http "mcp_http"
  @openai_api "openai_api"
  @whatsapp_webhook "whatsapp_webhook"

  @secure_headers [
    {"content-security-policy", "default-src 'none'; frame-ancestors 'none'"},
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"referrer-policy", "no-referrer"},
    {"cache-control", "no-store"}
  ]

  @type auth_context :: %{
          required(:surface) => String.t(),
          required(:client_id) => String.t(),
          required(:token_ref) => String.t(),
          required(:rate_limit) => map()
        }

  @spec api_secure_headers() :: [{String.t(), String.t()}]
  def api_secure_headers, do: @secure_headers

  @spec public_path?(String.t()) :: boolean()
  def public_path?("/mcp"), do: true
  def public_path?("/v1/" <> _rest), do: true
  def public_path?("/webhooks/whatsapp/" <> _phone_number_id), do: true
  def public_path?(_path), do: false

  @spec webhook_path?(String.t()) :: boolean()
  def webhook_path?("/webhooks/whatsapp/" <> _phone_number_id), do: true
  def webhook_path?(_path), do: false

  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes do
    case Settings.get("public_protocol.max_body_bytes") do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _other -> 1_048_576
    end
  end

  @spec content_length_allowed?(String.t() | nil, non_neg_integer()) ::
          :ok | {:error, :body_too_large}
  def content_length_allowed?(nil, _max), do: :ok
  def content_length_allowed?("", _max), do: :ok

  def content_length_allowed?(value, max) when is_binary(value) and is_integer(max) do
    case Integer.parse(value) do
      {length, ""} when length <= max -> :ok
      {length, ""} when length > max -> {:error, :body_too_large}
      _other -> :ok
    end
  end

  def content_length_allowed?(_value, _max), do: :ok

  @spec validate_surface_enabled(String.t()) :: :ok | {:error, term()}
  def validate_surface_enabled(@mcp_http) do
    with {:ok, true} <- Settings.get("mcp_server.enabled"),
         {:ok, true} <- Settings.get("mcp_server.streamable_http.enabled") do
      :ok
    else
      {:ok, false} -> {:error, :surface_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_surface_enabled(@openai_api) do
    case Settings.get("openai_api.enabled") do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :surface_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_surface_enabled(surface), do: {:error, {:invalid_surface, surface}}

  @spec authenticate(String.t(), map() | [{String.t(), String.t()}]) ::
          {:ok, auth_context()} | {:error, term()}
  def authenticate(surface, headers) when is_binary(surface) do
    with :ok <- validate_surface_enabled(surface),
         {:ok, client_id} <- client_id(headers),
         {:ok, token} <- bearer_token(headers),
         {:ok, auth} <- TokenAuth.verify(surface, client_id, token) do
      {:ok, auth}
    end
  end

  @spec authenticate_webhook(String.t(), map() | [{String.t(), String.t()}], binary(), String.t()) ::
          {:ok, auth_context()} | {:error, term()}
  def authenticate_webhook(@whatsapp_webhook = surface, headers, raw_body, path)
      when is_binary(raw_body) and is_binary(path) do
    with :ok <- validate_origin(headers, nil),
         {:ok, phone_number_id} <- webhook_phone_number_id(path),
         {:ok, config} <- whatsapp_webhook_config(),
         :ok <- validate_webhook_install(phone_number_id, config),
         {:ok, signature} <- webhook_signature(headers),
         {:ok, app_secret} <- fetch_secret(config.app_secret_ref, surface),
         :ok <- verify_webhook_signature(signature, app_secret, raw_body),
         auth <- webhook_auth_context(surface, phone_number_id, config),
         :ok <- rate_limit(auth) do
      {:ok, auth}
    end
  end

  def authenticate_webhook(surface, _headers, _raw_body, _path),
    do: {:error, {:invalid_surface, surface}}

  @spec authenticate_webhook_challenge(
          String.t(),
          map() | [{String.t(), String.t()}],
          String.t(),
          map()
        ) ::
          {:ok, String.t(), auth_context()} | {:error, term()}
  def authenticate_webhook_challenge(@whatsapp_webhook = surface, headers, path, params)
      when is_binary(path) and is_map(params) do
    with :ok <- validate_origin(headers, nil),
         {:ok, phone_number_id} <- webhook_phone_number_id(path),
         {:ok, config} <- whatsapp_webhook_config(),
         :ok <- validate_webhook_install(phone_number_id, config),
         {:ok, challenge} <- webhook_challenge(params),
         {:ok, supplied_token} <- webhook_verify_token(params),
         {:ok, expected_token} <- fetch_secret(config.verify_token_ref, surface),
         :ok <- verify_webhook_token(supplied_token, expected_token),
         auth <- webhook_auth_context(surface, phone_number_id, config),
         :ok <- rate_limit(auth) do
      {:ok, challenge, auth}
    end
  end

  def authenticate_webhook_challenge(surface, _headers, _path, _params),
    do: {:error, {:invalid_surface, surface}}

  @spec rate_limit(auth_context()) :: :ok | {:error, :rate_limited}
  def rate_limit(%{surface: surface, client_id: client_id, rate_limit: rate_limit}) do
    RateLimiter.check(surface, client_id, rate_limit)
  end

  @spec validate_mcp_protocol_version(map() | [{String.t(), String.t()}]) ::
          :ok | {:error, term()}
  def validate_mcp_protocol_version(headers) do
    case header(headers, "mcp-protocol-version") do
      nil -> :ok
      "" -> :ok
      version -> ProtocolVersions.validate(version)
    end
  end

  @spec validate_origin(map() | [{String.t(), String.t()}], String.t() | nil) ::
          :ok | {:error, :origin_denied}
  def validate_origin(headers, host) do
    case header(headers, "origin") do
      nil ->
        :ok

      origin ->
        if loopback_origin?(origin) and loopback_host?(host) do
          :ok
        else
          {:error, :origin_denied}
        end
    end
  end

  @spec public_context(auth_context()) :: map()
  def public_context(%{surface: surface, client_id: client_id}) do
    ContextBuilder.public_protocol_context(surface, client_id)
  end

  @type http_status :: 400 | 401 | 403 | 413 | 429

  @spec error_body(term()) :: %{
          required(String.t()) => %{
            required(String.t()) => String.t()
          }
        }
  def error_body(reason) do
    %{
      "error" => %{
        "message" => error_message(reason),
        "type" => error_type(reason),
        "code" => error_code(reason)
      }
    }
  end

  @spec status(term()) :: http_status()
  def status(:missing_client_id), do: 401
  def status(:missing_bearer_token), do: 401
  def status(:invalid_token), do: 401
  def status(:unknown_client), do: 401
  def status(:client_disabled), do: 401
  def status(:surface_disabled), do: 403
  def status(:rate_limited), do: 429
  def status(:body_too_large), do: 413
  def status(:origin_denied), do: 403
  def status(:webhook_disabled), do: 403
  def status(:webhook_install_denied), do: 403
  def status(:missing_webhook_signature), do: 401
  def status(:invalid_webhook_signature), do: 401
  def status(:missing_webhook_verify_token), do: 401
  def status(:invalid_webhook_verify_token), do: 401
  def status(:missing_webhook_challenge), do: 400
  def status(:missing_webhook_secret), do: 401
  def status({:invalid_client_id, _client_id}), do: 401
  def status({:invalid_surface, _surface}), do: 400
  def status({:secret_not_found, _secret_ref}), do: 401
  def status(%{message: "Unsupported MCP protocol version."}), do: 400
  def status(_reason), do: 400

  defp client_id(headers) do
    case header(headers, "x-allbert-client-id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :missing_client_id}
    end
  end

  defp bearer_token(headers) do
    case header(headers, "authorization") do
      "Bearer " <> token when token != "" -> {:ok, token}
      "bearer " <> token when token != "" -> {:ok, token}
      _other -> {:error, :missing_bearer_token}
    end
  end

  defp webhook_phone_number_id(path) do
    case String.split(path, "/", trim: true) do
      ["webhooks", "whatsapp", phone_number_id]
      when byte_size(phone_number_id) > 0 and byte_size(phone_number_id) <= 160 ->
        {:ok, URI.decode(phone_number_id)}

      _other ->
        {:error, :webhook_install_denied}
    end
  end

  defp whatsapp_webhook_config do
    with {:ok, true} <- raw_setting("channels.whatsapp.webhook_enabled"),
         {:ok, phone_number_id} <- non_empty_raw_setting("channels.whatsapp.phone_number_id"),
         {:ok, app_secret_ref} <- non_empty_raw_setting("channels.whatsapp.app_secret_ref"),
         {:ok, verify_token_ref} <-
           non_empty_raw_setting("channels.whatsapp.webhook_verify_token_ref") do
      {:ok,
       %{
         phone_number_id: phone_number_id,
         app_secret_ref: app_secret_ref,
         verify_token_ref: verify_token_ref,
         rate_limit: whatsapp_webhook_rate_limit()
       }}
    else
      {:ok, false} -> {:error, :webhook_disabled}
      {:ok, nil} -> {:error, :webhook_disabled}
      {:ok, ""} -> {:error, :missing_webhook_secret}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_webhook_install(phone_number_id, %{phone_number_id: phone_number_id}), do: :ok
  defp validate_webhook_install(_phone_number_id, _config), do: {:error, :webhook_install_denied}

  defp webhook_signature(headers) do
    case header(headers, "x-hub-signature-256") do
      "sha256=" <> hex = signature when byte_size(hex) == 64 -> {:ok, signature}
      nil -> {:error, :missing_webhook_signature}
      "" -> {:error, :missing_webhook_signature}
      _signature -> {:error, :invalid_webhook_signature}
    end
  end

  defp verify_webhook_signature(signature, app_secret, raw_body) do
    expected =
      :crypto.mac(:hmac, :sha256, app_secret, raw_body)
      |> Base.encode16(case: :lower)
      |> then(&("sha256=" <> &1))

    if secure_compare(signature, expected) do
      :ok
    else
      {:error, :invalid_webhook_signature}
    end
  end

  defp webhook_challenge(params) do
    case Map.get(params, "hub.challenge") do
      challenge when is_binary(challenge) and challenge != "" -> {:ok, challenge}
      _other -> {:error, :missing_webhook_challenge}
    end
  end

  defp webhook_verify_token(params) do
    case Map.get(params, "hub.verify_token") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _other -> {:error, :missing_webhook_verify_token}
    end
  end

  defp verify_webhook_token(supplied_token, expected_token) do
    if secure_compare(supplied_token, expected_token) do
      :ok
    else
      {:error, :invalid_webhook_verify_token}
    end
  end

  defp fetch_secret(secret_ref, surface) do
    Secrets.get_secret(secret_ref, %{
      actor: "public-protocol:#{surface}",
      channel: :public_protocol,
      trusted?: true
    })
  end

  defp webhook_auth_context(surface, phone_number_id, config) do
    %{
      surface: surface,
      client_id: phone_number_id,
      token_ref: config.app_secret_ref,
      rate_limit: config.rate_limit
    }
  end

  defp whatsapp_webhook_rate_limit do
    %{
      limit: raw_setting_value("channels.whatsapp.webhook_rate_limit.limit", 60),
      period_ms: raw_setting_value("channels.whatsapp.webhook_rate_limit.period_ms", 60_000),
      burst: raw_setting_value("channels.whatsapp.webhook_rate_limit.burst", 10)
    }
  end

  defp raw_setting(key) do
    case Store.resolved_settings() do
      {:ok, settings, _user_settings} -> {:ok, get_dotted(settings, key)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp non_empty_raw_setting(key) do
    case raw_setting(key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {:missing_setting, key, value}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp raw_setting_value(key, default) do
    case raw_setting(key) do
      {:ok, value} when is_integer(value) -> value
      _other -> default
    end
  end

  defp get_dotted(settings, key) do
    get_in(settings, String.split(key, "."))
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp header(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {header, value} when is_binary(header) and is_binary(value) ->
        if String.downcase(header) == key, do: value

      _entry ->
        nil
    end)
  end

  defp header(headers, key) when is_map(headers) do
    Map.get(headers, key) || Map.get(headers, String.upcase(key))
  end

  defp header(_headers, _key), do: nil

  defp loopback_origin?(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        loopback_host?(host)

      _uri ->
        false
    end
  end

  defp loopback_host?(nil), do: false
  defp loopback_host?("localhost"), do: true
  defp loopback_host?("127.0.0.1"), do: true
  defp loopback_host?("::1"), do: true
  defp loopback_host?("[::1]"), do: true
  defp loopback_host?(_host), do: false

  defp error_message(:missing_client_id), do: "Missing public protocol client id."
  defp error_message(:missing_bearer_token), do: "Missing bearer token."
  defp error_message(:invalid_token), do: "Invalid bearer token."
  defp error_message(:unknown_client), do: "Unknown public protocol client."
  defp error_message(:client_disabled), do: "Public protocol client is disabled."
  defp error_message(:surface_disabled), do: "Public protocol surface is disabled."
  defp error_message(:rate_limited), do: "Public protocol client is rate limited."
  defp error_message(:body_too_large), do: "Public protocol request body is too large."
  defp error_message(:webhook_disabled), do: "Webhook surface is disabled."
  defp error_message(:webhook_install_denied), do: "Webhook install is not allowed."
  defp error_message(:missing_webhook_signature), do: "Missing webhook signature."
  defp error_message(:invalid_webhook_signature), do: "Invalid webhook signature."
  defp error_message(:missing_webhook_verify_token), do: "Missing webhook verify token."
  defp error_message(:invalid_webhook_verify_token), do: "Invalid webhook verify token."
  defp error_message(:missing_webhook_challenge), do: "Missing webhook challenge."
  defp error_message(:missing_webhook_secret), do: "Missing webhook secret."
  defp error_message({:secret_not_found, _secret_ref}), do: "Webhook secret is not configured."
  defp error_message({:missing_setting, key, _value}), do: "Missing webhook setting #{key}."

  defp error_message(:origin_denied),
    do: "Origin is not allowed for this public protocol surface."

  defp error_message({:invalid_client_id, _client_id}), do: "Invalid public protocol client id."
  defp error_message({:invalid_surface, _surface}), do: "Invalid public protocol surface."
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(reason), do: "Public protocol request failed: #{inspect(reason)}."

  defp error_type(:rate_limited), do: "rate_limit_error"
  defp error_type(:body_too_large), do: "request_too_large"
  defp error_type(:origin_denied), do: "authorization_error"
  defp error_type(:surface_disabled), do: "authorization_error"
  defp error_type(:webhook_disabled), do: "authorization_error"
  defp error_type(:webhook_install_denied), do: "authorization_error"

  defp error_type(reason) when reason in [:missing_client_id, :missing_bearer_token],
    do: "authentication_error"

  defp error_type(reason) when reason in [:invalid_token, :unknown_client, :client_disabled],
    do: "authentication_error"

  defp error_type(reason)
       when reason in [
              :missing_webhook_signature,
              :invalid_webhook_signature,
              :missing_webhook_verify_token,
              :invalid_webhook_verify_token,
              :missing_webhook_secret
            ],
       do: "authentication_error"

  defp error_type(_reason), do: "invalid_request_error"

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _value}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(%{code: code}) when is_integer(code), do: Integer.to_string(code)
  defp error_code(_reason), do: "invalid_request"
end
