defmodule AllbertAssist.Mcp.CodecTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertAssist.Mcp.Codec

  test "encodes MCP requests through the Hermes message codec" do
    assert {:ok, encoded, 123} = Codec.request("tools/list", %{}, 123)
    assert {:ok, request} = Jason.decode(String.trim(encoded))

    assert request["jsonrpc"] == "2.0"
    assert request["id"] == 123
    assert request["method"] == "tools/list"
    assert request["params"] == %{}
  end

  test "rejects invalid MCP request params through Hermes schema validation" do
    assert {:error, {:protocol_error, %{code: :protocol_error}}} =
             Codec.request("resources/read", %{}, 123)
  end

  test "decodes and validates matching JSON-RPC responses" do
    body = ~s({"jsonrpc":"2.0","id":123,"result":{"tools":[]}})

    assert {:ok, %{"tools" => []}} = Codec.decode_response(body, 123)
  end

  test "redacts JSON-RPC server error messages" do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 123,
        "error" => %{"code" => -32_000, "message" => "secret failure"}
      })

    assert {:error, {:json_rpc_error, error}} = Codec.decode_response(body, 123)
    assert error["code"] == -32_000
    assert error["message"] == "MCP server returned a JSON-RPC error."
  end
end
