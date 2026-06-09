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

  @mcp_http "mcp_http"
  @openai_api "openai_api"

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
  def public_path?(_path), do: false

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
    %{
      public_protocol: %{surface: surface, client_id: client_id},
      request: %{
        channel: String.to_atom(surface),
        operator_id: "public-protocol:#{client_id}"
      }
    }
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
  def status({:invalid_client_id, _client_id}), do: 401
  def status({:invalid_surface, _surface}), do: 400
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

  defp error_type(reason) when reason in [:missing_client_id, :missing_bearer_token],
    do: "authentication_error"

  defp error_type(reason) when reason in [:invalid_token, :unknown_client, :client_disabled],
    do: "authentication_error"

  defp error_type(_reason), do: "invalid_request_error"

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _value}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(%{code: code}) when is_integer(code), do: Integer.to_string(code)
  defp error_code(_reason), do: "invalid_request"
end
