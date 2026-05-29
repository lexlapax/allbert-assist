defmodule AllbertAssist.Mcp.Client do
  @moduledoc """
  Minimal MCP client over the Allbert MCP transport boundary.

  Protocol message validation and wire encoding route through
  `AllbertAssist.Mcp.Codec`, which wraps `:hermes_mcp`. Transport, settings,
  security, and audit remain Allbert-owned.
  """

  alias AllbertAssist.Mcp.Codec
  alias AllbertAssist.Mcp.Diagnostics
  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Mcp.Transport

  @protocol_version "2025-03-26"
  @client_info %{"name" => "Allbert", "version" => "0.40"}

  @type discovery_result :: %{
          protocol_version: String.t() | nil,
          tools: [map()],
          resources: [map()],
          next_cursor: String.t() | nil
        }

  @spec initialize(ServerConfig.t(), map()) :: {:ok, map()} | {:error, term()}
  def initialize(%ServerConfig{} = config, context \\ %{}) do
    with_open(config, context, fn conn ->
      case initialize_connection(conn) do
        {:ok, init, _conn} -> {:ok, init}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec list_tools(ServerConfig.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_tools(%ServerConfig{} = config, context \\ %{}, opts \\ []) do
    with_open(config, context, fn conn ->
      with {:ok, init, conn} <- initialize_connection(conn),
           {:ok, result, _conn} <- request(conn, "tools/list", list_params(opts)) do
        {:ok,
         %{
           protocol_version: protocol_version(init),
           tools: Map.get(result, "tools", []),
           next_cursor: Map.get(result, "nextCursor")
         }}
      end
    end)
  end

  @spec list_resources(ServerConfig.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_resources(%ServerConfig{} = config, context \\ %{}, opts \\ []) do
    with_open(config, context, fn conn ->
      with {:ok, init, conn} <- initialize_connection(conn),
           {:ok, result, _conn} <- request(conn, "resources/list", list_params(opts)) do
        {:ok,
         %{
           protocol_version: protocol_version(init),
           resources: Map.get(result, "resources", []),
           next_cursor: Map.get(result, "nextCursor")
         }}
      end
    end)
  end

  @spec read_resource(ServerConfig.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def read_resource(%ServerConfig{} = config, uri, context \\ %{}) when is_binary(uri) do
    with_open(config, context, fn conn ->
      with {:ok, init, conn} <- initialize_connection(conn),
           {:ok, result, _conn} <- request(conn, "resources/read", %{"uri" => uri}) do
        {:ok,
         %{protocol_version: protocol_version(init), contents: Map.get(result, "contents", [])}}
      end
    end)
  end

  @spec call_tool(ServerConfig.t(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def call_tool(%ServerConfig{} = config, name, arguments, context \\ %{})
      when is_binary(name) and is_map(arguments) do
    with_open(config, context, fn conn ->
      with {:ok, init, conn} <- initialize_connection(conn),
           {:ok, result, _conn} <-
             request(conn, "tools/call", %{"name" => name, "arguments" => arguments}) do
        {:ok, %{protocol_version: protocol_version(init), result: result}}
      end
    end)
  end

  defp with_open(config, context, fun) do
    with :ok <- require_enabled(config),
         {:ok, conn} <- Transport.open(config, context) do
      try do
        fun.(conn)
      after
        Transport.close(conn)
      end
    end
  end

  defp require_enabled(%ServerConfig{enabled?: true}), do: :ok

  defp require_enabled(_config),
    do: {:error, {:server_disabled, Diagnostics.new(:server_disabled)}}

  defp initialize_connection(conn) do
    with {:ok, init_result, conn} <-
           request(conn, "initialize", %{
             "protocolVersion" => @protocol_version,
             "capabilities" => %{},
             "clientInfo" => @client_info
           }),
         {:ok, conn} <- notify(conn, "notifications/initialized", %{}) do
      {:ok, init_result, conn}
    end
  end

  defp request(conn, method, params) do
    with {:ok, encoded, request_id} <- Codec.request(method, params),
         {:ok, body, conn} <-
           Transport.request(conn, encoded, request_id, timeout_ms: conn.config.timeout_ms),
         {:ok, result} <- Codec.decode_response(body, request_id) do
      {:ok, result, conn}
    else
      {:error, reason, _conn} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp notify(conn, method, params) do
    with {:ok, encoded} <- Codec.notification(method, params),
         {:ok, conn} <- Transport.notify(conn, encoded) do
      {:ok, conn}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_params(opts) do
    opts
    |> Keyword.take([:cursor])
    |> Enum.reduce(%{}, fn
      {:cursor, cursor}, acc when is_binary(cursor) and cursor != "" ->
        Map.put(acc, "cursor", cursor)

      _entry, acc ->
        acc
    end)
  end

  defp protocol_version(result) do
    Map.get(result, "protocolVersion") || Map.get(result, "protocol_version")
  end
end
