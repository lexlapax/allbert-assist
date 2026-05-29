defmodule AllbertAssist.Mcp.Client do
  @moduledoc """
  Minimal native JSON-RPC MCP client over the Allbert MCP transport boundary.
  """

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
    payload = request_payload(method, params)

    case Transport.request(conn, payload, timeout_ms: conn.config.timeout_ms) do
      {:ok, %{"error" => error}, _conn} ->
        {:error, {:json_rpc_error, redact_error(error)}}

      {:ok, %{"result" => result}, conn} when is_map(result) ->
        {:ok, result, conn}

      {:ok, _response, _conn} ->
        {:error, {:protocol_error, Diagnostics.new(:protocol_error)}}

      {:error, reason, _conn} ->
        {:error, reason}
    end
  end

  defp notify(conn, method, params) do
    case Transport.notify(conn, notification(method, params)) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason, _conn} -> {:error, reason}
    end
  end

  defp request_payload(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }
  end

  defp notification(method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
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

  defp redact_error(error) when is_map(error) do
    error
    |> Map.take(["code", "message"])
    |> Map.update("message", "MCP server returned a JSON-RPC error.", fn _value ->
      "MCP server returned a JSON-RPC error."
    end)
  end

  defp redact_error(_error), do: %{"message" => "MCP server returned a JSON-RPC error."}
end
