defmodule AllbertAssist.Mcp.Codec do
  @moduledoc """
  MCP JSON-RPC protocol codec.

  This module isolates the `:hermes_mcp` protocol message dependency from
  Allbert's transport and action boundaries. Hermes validates and encodes MCP
  wire messages; Allbert remains responsible for server configuration, egress,
  permission checks, audit, and action execution.
  """

  alias AllbertAssist.Mcp.Diagnostics
  alias Hermes.MCP.Message

  @type request_id :: String.t() | integer()

  @spec request(String.t(), map(), request_id() | nil) ::
          {:ok, String.t(), request_id()} | {:error, term()}
  def request(method, params, id \\ nil) when is_binary(method) and is_map(params) do
    id = id || System.unique_integer([:positive])

    case Message.encode_request(%{"method" => method, "params" => params}, id) do
      {:ok, encoded} -> {:ok, encoded, id}
      {:error, _reason} -> {:error, {:protocol_error, Diagnostics.new(:protocol_error)}}
    end
  end

  @spec notification(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def notification(method, params \\ %{}) when is_binary(method) and is_map(params) do
    case Message.encode_notification(%{"method" => method, "params" => params}) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, {:protocol_error, Diagnostics.new(:protocol_error)}}
    end
  end

  @spec decode_response(String.t(), request_id() | nil) :: {:ok, map()} | {:error, term()}
  def decode_response(body, expected_id \\ nil) when is_binary(body) do
    with {:ok, messages} <- decode_messages(body),
         {:ok, response} <- find_response(messages, expected_id) do
      case response do
        %{"result" => result} when is_map(result) ->
          {:ok, result}

        %{"error" => error} ->
          {:error, {:json_rpc_error, redact_error(error)}}

        _message ->
          {:error, {:protocol_error, Diagnostics.new(:protocol_error)}}
      end
    end
  end

  defp decode_messages(body) do
    case Message.decode(body) do
      {:ok, [_message | _rest] = messages} ->
        {:ok, messages}

      {:ok, []} ->
        {:error, {:protocol_error, Diagnostics.new(:protocol_error)}}

      {:error, _reason} ->
        {:error, {:protocol_error, Diagnostics.new(:protocol_error)}}
    end
  end

  defp find_response(messages, nil) do
    case Enum.find(messages, &response?/1) do
      nil -> {:error, {:protocol_error, Diagnostics.new(:protocol_error)}}
      response -> {:ok, response}
    end
  end

  defp find_response(messages, expected_id) do
    case Enum.find(messages, &(response?(&1) and Map.get(&1, "id") == expected_id)) do
      nil -> {:error, {:protocol_error, Diagnostics.new(:protocol_error)}}
      response -> {:ok, response}
    end
  end

  defp response?(%{"result" => _result, "id" => _id}), do: true
  defp response?(%{"error" => _error, "id" => _id}), do: true
  defp response?(_message), do: false

  defp redact_error(error) when is_map(error) do
    error
    |> Map.take(["code", "message"])
    |> Map.update("message", "MCP server returned a JSON-RPC error.", fn _value ->
      "MCP server returned a JSON-RPC error."
    end)
  end

  defp redact_error(_error), do: %{"message" => "MCP server returned a JSON-RPC error."}
end
