defmodule AllbertAssistWeb.PublicProtocol.McpHttpController do
  @moduledoc """
  Allbert-owned MCP streamable-HTTP ingress for v0.51.

  This controller intentionally does not mount Hermes StreamableHTTP. It handles
  the v0.51 JSON request subset after Allbert's auth/rate-limit/header pipeline.
  """

  use AllbertAssistWeb, :controller

  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.PublicProtocol.Mcp.{ProtocolVersions, Runtime, Schema}

  @surface "mcp_http"

  plug AllbertAssistWeb.Plugs.PublicProtocolAuth,
       [surface: "mcp_http"] when action in [:handle, :delete]

  plug AllbertAssistWeb.Plugs.McpProtocolVersion when action in [:handle, :delete]

  def handle(conn, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = request) do
    case dispatch(method, Map.get(request, "params", %{}), conn) do
      {:ok, result} ->
        conn
        |> maybe_put_session_header()
        |> json(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

      {:error, {status, code, message, data}} ->
        rpc_error(conn, status, id, code, message, data)
    end
  end

  def handle(conn, request) do
    id = if is_map(request), do: Map.get(request, "id")

    rpc_error(conn, 400, id, -32_600, "Invalid JSON-RPC request.", %{})
  end

  def delete(conn, _params) do
    conn
    |> put_status(405)
    |> json(%{
      "error" => %{
        "message" => "MCP HTTP session DELETE is not implemented in v0.51.",
        "type" => "invalid_request_error",
        "code" => "method_not_allowed"
      }
    })
  end

  defp dispatch("initialize", params, _conn) when is_map(params) do
    requested = Map.get(params, "protocolVersion", ProtocolVersions.latest())

    with :ok <- ProtocolVersions.validate(requested) do
      {:ok,
       %{
         "protocolVersion" => requested,
         "serverInfo" => %{
           "name" => "allbert-assist",
           "version" => CoreApp.version()
         },
         "capabilities" => %{
           "tools" => %{},
           "resources" => %{}
         }
       }}
    else
      {:error, error} ->
        {:error, {400, -32_602, error.message, error.data}}
    end
  end

  defp dispatch("tools/list", _params, _conn) do
    with {:ok, tools} <- Runtime.enabled_tools(@surface) do
      {:ok,
       %{
         "tools" =>
           Enum.map(tools, fn tool ->
             %{
               "name" => tool.name,
               "description" => tool.module.description(),
               "inputSchema" => Schema.input_schema(tool.module)
             }
           end)
       }}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, conn) when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    with {:ok, payload} <-
           Runtime.call_tool(name, arguments, conn.assigns.public_protocol_context, @surface) do
      {:ok, tool_result(payload)}
    else
      {:error, reason} ->
        {:error, {400, -32_602, "MCP tool call failed.", %{reason: inspect(reason)}}}
    end
  end

  defp dispatch("resources/list", _params, _conn) do
    with {:ok, resources} <- Runtime.enabled_resources(@surface) do
      {:ok,
       %{
         "resources" =>
           Enum.map(resources, fn resource ->
             %{
               "uri" => resource.uri,
               "name" => resource.name,
               "description" => resource.description,
               "mimeType" => resource.mime_type
             }
           end)
       }}
    end
  end

  defp dispatch("resources/read", %{"uri" => uri}, conn) when is_binary(uri) do
    with {:ok, payload} <-
           Runtime.read_resource(uri, conn.assigns.public_protocol_context, @surface) do
      {:ok,
       %{
         "contents" => [
           %{
             "uri" => uri,
             "mimeType" => "application/json",
             "text" => Jason.encode!(payload)
           }
         ]
       }}
    else
      {:error, reason} ->
        {:error, {404, -32_002, "MCP resource was not found.", %{reason: inspect(reason)}}}
    end
  end

  defp dispatch(method, _params, _conn),
    do: {:error, {400, -32_601, "Unsupported MCP method: #{method}.", %{}}}

  defp tool_result(payload) do
    status = Map.get(payload, :status, Map.get(payload, "status"))
    safe_payload = json_safe(payload)

    is_error? =
      to_string(status) in ["denied", "error", "failed", "unsupported", "unavailable"]

    %{
      "content" => [
        %{
          "type" => "text",
          "text" => Jason.encode!(safe_payload)
        }
      ],
      "structuredContent" => safe_payload,
      "isError" => is_error?
    }
  end

  defp rpc_error(conn, status, id, code, message, data) do
    conn
    |> put_status(status)
    |> maybe_put_session_header()
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => code,
        "message" => message,
        "data" => data
      }
    })
  end

  defp maybe_put_session_header(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [session_id | _rest] when session_id != "" ->
        put_resp_header(conn, "mcp-session-id", session_id)

      _other ->
        conn
    end
  end

  defp json_safe(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp stringify_value(value) when is_map(value) and not is_struct(value),
    do: json_safe(value)

  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
