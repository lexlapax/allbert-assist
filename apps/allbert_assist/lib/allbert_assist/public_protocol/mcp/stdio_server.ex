defmodule AllbertAssist.PublicProtocol.Mcp.StdioServer do
  @moduledoc """
  Allbert-owned MCP stdio JSON-RPC adapter for v0.51.

  The adapter owns only stdio framing and process-local client identity. Tool
  calls and resource reads still cross the shared public MCP runtime, where
  Settings Central exposure and action-runner authority are enforced.
  """

  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.PublicProtocol.Mcp.{ProtocolVersions, Runtime, Schema}
  alias AllbertAssist.Surfaces.ContextBuilder

  defstruct initialized?: false, client_id: "stdio-client"

  @type state :: %__MODULE__{initialized?: boolean(), client_id: String.t()}

  @spec new_state() :: state()
  def new_state, do: %__MODULE__{}

  @spec serve_stdio() :: :ok
  def serve_stdio do
    _final_state =
      IO.stream(:stdio, :line)
      |> Enum.reduce(new_state(), fn line, state ->
        {:ok, outbound, state} = handle_line(line, state)
        Enum.each(outbound, &IO.write(:stdio, &1))
        state
      end)

    :ok
  end

  @spec handle_line(String.t(), state()) :: {:ok, [String.t()], state()}
  def handle_line(line, %__MODULE__{} = state) when is_binary(line) do
    case Jason.decode(String.trim_trailing(line)) do
      {:ok, messages} when is_list(messages) ->
        handle_messages(messages, state)

      {:ok, message} when is_map(message) ->
        handle_messages([message], state)

      {:ok, _other} ->
        {:ok, [encode_line(error_response(nil, -32_600, "Invalid JSON-RPC request.", %{}))],
         state}

      {:error, _reason} ->
        {:ok, [encode_line(error_response(nil, -32_700, "Parse error.", %{}))], state}
    end
  end

  defp handle_messages(messages, state) do
    Enum.reduce(messages, {:ok, [], state}, fn message, {:ok, outbound, state} ->
      {:ok, responses, state} = handle_message(message, state)
      {:ok, outbound ++ responses, state}
    end)
  end

  defp handle_message(%{"jsonrpc" => "2.0", "method" => method} = message, state)
       when is_binary(method) do
    request_id = Map.get(message, "id")
    params = Map.get(message, "params", %{})

    if notification?(message) do
      {:ok, [], handle_notification(method, params, state)}
    else
      case dispatch(method, params, request_id, state) do
        {:ok, result, state} ->
          {:ok, [encode_line(success_response(request_id, result))], state}

        {:error, {code, message, data}, state} ->
          {:ok, [encode_line(error_response(request_id, code, message, data))], state}
      end
    end
  end

  defp handle_message(%{"id" => _id} = message, state)
       when is_map_key(message, "result") or is_map_key(message, "error") do
    {:ok, [], state}
  end

  defp handle_message(message, state) when is_map(message) do
    id = Map.get(message, "id")
    {:ok, [encode_line(error_response(id, -32_600, "Invalid JSON-RPC request.", %{}))], state}
  end

  defp handle_message(_message, state) do
    {:ok, [encode_line(error_response(nil, -32_600, "Invalid JSON-RPC request.", %{}))], state}
  end

  defp handle_notification("notifications/initialized", _params, state), do: state
  defp handle_notification(_method, _params, state), do: state

  defp dispatch("initialize", params, _request_id, state) when is_map(params) do
    requested = Map.get(params, "protocolVersion", ProtocolVersions.latest())

    case ProtocolVersions.validate(requested) do
      :ok ->
        client_id = client_id(params)
        state = %{state | initialized?: true, client_id: client_id}
        {:ok, initialize_result(requested), state}

      {:error, error} ->
        {:error, {error.code, error.message, error.data}, state}
    end
  end

  defp dispatch("tools/list", _params, _request_id, state) do
    with :ok <- ensure_initialized(state),
         {:ok, tools} <- Runtime.enabled_tools("mcp_stdio") do
      {:ok, %{"tools" => Enum.map(tools, &tool_definition/1)}, state}
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, _request_id, state)
       when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    with :ok <- ensure_initialized(state),
         {:ok, payload} <- Runtime.call_tool(name, arguments, context(state), "mcp_stdio") do
      {:ok, tool_result(payload), state}
    else
      {:error, error = {_code, _message, _data}} ->
        {:error, error, state}

      {:error, reason} ->
        {:error, {-32_602, "MCP tool call failed.", %{reason: inspect(reason)}}, state}
    end
  end

  defp dispatch("tools/call", _params, _request_id, state),
    do: {:error, {-32_602, "MCP tool call requires a tool name.", %{}}, state}

  defp dispatch("resources/list", _params, _request_id, state) do
    with :ok <- ensure_initialized(state),
         {:ok, resources} <- Runtime.enabled_resources("mcp_stdio") do
      {:ok, %{"resources" => Enum.map(resources, &resource_definition/1)}, state}
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp dispatch("resources/read", %{"uri" => uri}, _request_id, state) when is_binary(uri) do
    with :ok <- ensure_initialized(state),
         {:ok, payload} <- Runtime.read_resource(uri, context(state), "mcp_stdio") do
      {:ok,
       %{
         "contents" => [
           %{
             "uri" => uri,
             "mimeType" => "application/json",
             "text" => Jason.encode!(payload)
           }
         ]
       }, state}
    else
      {:error, error = {_code, _message, _data}} ->
        {:error, error, state}

      {:error, reason} ->
        {:error, {-32_002, "MCP resource was not found.", %{reason: inspect(reason)}}, state}
    end
  end

  defp dispatch("resources/read", _params, _request_id, state),
    do: {:error, {-32_602, "MCP resource read requires a URI.", %{}}, state}

  defp dispatch(method, _params, _request_id, state),
    do: {:error, {-32_601, "Unsupported MCP method: #{method}.", %{}}, state}

  defp ensure_initialized(%{initialized?: true}), do: :ok

  defp ensure_initialized(_state),
    do: {:error, {-32_000, "MCP session must be initialized first.", %{}}}

  defp initialize_result(protocol_version) do
    %{
      "protocolVersion" => protocol_version,
      "serverInfo" => %{
        "name" => "allbert-assist",
        "version" => CoreApp.version()
      },
      "capabilities" => %{
        "tools" => %{},
        "resources" => %{}
      }
    }
  end

  defp tool_definition(tool) do
    %{
      "name" => tool.name,
      "description" => tool.module.description(),
      "inputSchema" => Schema.input_schema(tool.module)
    }
  end

  defp resource_definition(resource) do
    %{
      "uri" => resource.uri,
      "name" => resource.name,
      "description" => resource.description,
      "mimeType" => resource.mime_type
    }
  end

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

  defp context(state) do
    ContextBuilder.public_protocol_context("mcp_stdio", state.client_id)
  end

  defp client_id(%{"clientInfo" => %{"name" => name}}) when is_binary(name) and name != "",
    do: name

  defp client_id(%{"clientInfo" => %{"title" => title}}) when is_binary(title) and title != "",
    do: title

  defp client_id(_params), do: "stdio-client"

  defp notification?(message), do: not Map.has_key?(message, "id")

  defp success_response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => code,
        "message" => message,
        "data" => data
      }
    }
  end

  defp encode_line(message), do: Jason.encode!(message) <> "\n"

  defp json_safe(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp json_safe(value), do: value

  defp stringify_value(value) when is_map(value) and not is_struct(value),
    do: json_safe(value)

  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
