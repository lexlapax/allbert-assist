defmodule AllbertAssist.Mcp.ServerConfig do
  @moduledoc """
  Resolves MCP server settings into a bounded runtime config.

  This module is a plain module, not a GenServer or Jido agent, because it owns
  no durable state. It reads Settings Central and resolves secrets at call time.
  """

  alias AllbertAssist.Mcp.Diagnostics
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store

  @id_pattern ~r/^[A-Za-z0-9_-]+$/
  @default_timeout_ms 5_000
  @default_max_response_bytes 1_048_576

  @enforce_keys [:server_id, :enabled?, :transport]
  defstruct [
    :server_id,
    :enabled?,
    :transport,
    :base_url,
    :command,
    args: [],
    env: %{},
    headers: %{},
    auth_ref: nil,
    tool_allowlist: [],
    tool_denylist: [],
    confirmation: "required",
    timeout_ms: @default_timeout_ms,
    max_response_bytes: @default_max_response_bytes,
    credential_status: :not_required
  ]

  @type transport :: :stdio | :sse | :streamable_http
  @type t :: %__MODULE__{
          server_id: String.t(),
          enabled?: boolean(),
          transport: transport(),
          base_url: String.t() | nil,
          command: String.t() | nil,
          args: [String.t()],
          env: %{String.t() => String.t()},
          headers: %{String.t() => String.t()},
          auth_ref: String.t() | nil,
          tool_allowlist: [String.t()],
          tool_denylist: [String.t()],
          confirmation: String.t(),
          timeout_ms: pos_integer(),
          max_response_bytes: pos_integer(),
          credential_status: :configured | :missing | :not_required
        }

  @spec resolve(String.t()) :: {:ok, t()} | {:error, term()}
  def resolve(server_id) when is_binary(server_id) do
    with :ok <- validate_server_id(server_id),
         {:ok, settings, _user_settings} <- Store.resolved_settings(),
         servers = get_in(settings, ["mcp", "servers"]) || %{},
         {:ok, attrs} <- fetch_server(servers, server_id),
         {:ok, config} <- build(server_id, attrs),
         {:ok, config} <- resolve_secret_refs(config) do
      {:ok, config}
    end
  end

  def resolve(_server_id), do: {:error, :invalid_server_id}

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = config) do
    %{
      server_id: config.server_id,
      enabled?: config.enabled?,
      transport: config.transport,
      redacted_host: redacted_host(config),
      command: if(config.transport == :stdio, do: config.command),
      args_count: length(config.args),
      env_keys: config.env |> Map.keys() |> Enum.sort(),
      header_keys: config.headers |> Map.keys() |> Enum.sort(),
      credential_status: config.credential_status,
      tool_allowlist_count: length(config.tool_allowlist),
      tool_denylist_count: length(config.tool_denylist),
      confirmation: config.confirmation
    }
  end

  @spec redacted_host(t()) :: String.t()
  def redacted_host(%__MODULE__{transport: :stdio, command: command}), do: "stdio:#{command}"

  def redacted_host(%__MODULE__{base_url: base_url}) when is_binary(base_url) do
    base_url
    |> URI.parse()
    |> case do
      %URI{scheme: "https", host: host, port: 443} when is_binary(host) -> host
      %URI{scheme: "http", host: host, port: 80} when is_binary(host) -> host
      %URI{host: host, port: nil} when is_binary(host) -> host
      %URI{host: host, port: port} when is_binary(host) -> "#{host}:#{port}"
      _uri -> "unknown"
    end
  end

  def redacted_host(_config), do: "unknown"

  defp validate_server_id(server_id) do
    if Regex.match?(@id_pattern, server_id) do
      :ok
    else
      {:error, :invalid_server_id}
    end
  end

  defp fetch_server(servers, server_id) when is_map(servers) do
    case Map.get(servers, server_id) do
      attrs when is_map(attrs) -> {:ok, attrs}
      _other -> {:error, {:server_not_configured, Diagnostics.new(:server_not_configured)}}
    end
  end

  defp fetch_server(_servers, _server_id), do: {:error, :invalid_mcp_servers}

  defp build(server_id, attrs) do
    with {:ok, transport} <- transport(Map.get(attrs, "transport")) do
      {:ok,
       %__MODULE__{
         server_id: server_id,
         enabled?: Map.get(attrs, "enabled", false),
         transport: transport,
         base_url: Map.get(attrs, "base_url"),
         command: Map.get(attrs, "command"),
         args: Map.get(attrs, "args", []),
         env: Map.get(attrs, "env", %{}),
         headers: Map.get(attrs, "headers", %{}),
         auth_ref: Map.get(attrs, "auth_ref"),
         tool_allowlist: Map.get(attrs, "tool_allowlist", []),
         tool_denylist: Map.get(attrs, "tool_denylist", []),
         confirmation: Map.get(attrs, "confirmation", "required")
       }}
    end
  end

  defp transport("stdio"), do: {:ok, :stdio}
  defp transport("sse"), do: {:ok, :sse}
  defp transport("streamable_http"), do: {:ok, :streamable_http}
  defp transport(_transport), do: {:error, :invalid_transport}

  defp resolve_secret_refs(%__MODULE__{} = config) do
    with {:ok, env} <- resolve_secret_map(config.env),
         {:ok, headers} <- resolve_secret_map(config.headers),
         {:ok, credential_status} <- credential_status(config.auth_ref) do
      {:ok, %{config | env: env, headers: headers, credential_status: credential_status}}
    end
  end

  defp resolve_secret_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve_secret_value(value) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_secret_value("secret://mcp/" <> _rest = ref) do
    case Secrets.get_secret(ref) do
      {:ok, value} ->
        {:ok, value}

      {:error, _reason} ->
        {:error, {:credential_unavailable, Diagnostics.new(:credential_unavailable)}}
    end
  end

  defp resolve_secret_value(value) when is_binary(value), do: {:ok, value}

  defp credential_status(nil), do: {:ok, :not_required}

  defp credential_status(ref) do
    case Secrets.status(ref) do
      :configured -> {:ok, :configured}
      :missing -> {:ok, :missing}
    end
  end
end
