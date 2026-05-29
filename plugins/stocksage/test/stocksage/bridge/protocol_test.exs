defmodule StockSage.Bridge.ProtocolTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias StockSage.Bridge.Protocol

  describe "valid_action?/1" do
    test "recognizes ping and run_analysis" do
      assert Protocol.valid_action?("ping")
      assert Protocol.valid_action?("run_analysis")
    end

    test "rejects unknown actions and non-strings" do
      refute Protocol.valid_action?("invoke_shell")
      refute Protocol.valid_action?("")
      refute Protocol.valid_action?(:ping)
      refute Protocol.valid_action?(nil)
    end
  end

  describe "encode_request/1" do
    test "encodes a valid ping request with newline terminator" do
      assert {:ok, binary} = Protocol.encode_request(%{id: "abc", action: "ping"})
      assert String.ends_with?(binary, "\n")
      assert {:ok, decoded} = Jason.decode(String.trim(binary))
      assert decoded["id"] == "abc"
      assert decoded["action"] == "ping"
    end

    test "encodes a run_analysis request and preserves extra fields" do
      assert {:ok, binary} =
               Protocol.encode_request(%{
                 id: "req-1",
                 action: "run_analysis",
                 ticker: "AAPL",
                 analysis_date: "2026-05-01",
                 engine: "tradingagents"
               })

      assert {:ok, decoded} = Jason.decode(String.trim(binary))
      assert decoded["ticker"] == "AAPL"
      assert decoded["analysis_date"] == "2026-05-01"
      assert decoded["engine"] == "tradingagents"
    end

    test "rejects requests missing id" do
      assert {:error, :missing_id} = Protocol.encode_request(%{action: "ping"})
    end

    test "rejects requests missing action" do
      assert {:error, :missing_action} = Protocol.encode_request(%{id: "x"})
    end

    test "rejects unknown actions" do
      assert {:error, {:unknown_action, "drop_table"}} =
               Protocol.encode_request(%{id: "x", action: "drop_table"})
    end

    test "rejects non-map input" do
      assert {:error, :invalid_request} = Protocol.encode_request("ping")
    end
  end

  describe "decode_response/1" do
    test "parses a valid ok response" do
      line = ~s({"id":"r1","status":"ok","result":"pong"})
      assert {:ok, response} = Protocol.decode_response(line)
      assert response["id"] == "r1"
      assert response["status"] == "ok"
      assert response["result"] == "pong"
    end

    test "parses a valid error response" do
      line = ~s({"id":"r2","status":"error","reason":"bad ticker"})
      assert {:ok, response} = Protocol.decode_response(line)
      assert response["status"] == "error"
      assert response["reason"] == "bad ticker"
    end

    test "rejects malformed JSON" do
      assert {:error, {:invalid_json, _msg}} = Protocol.decode_response("not json")
    end

    test "rejects empty input" do
      assert {:error, :empty_response} = Protocol.decode_response("   ")
    end

    test "rejects responses without id or status" do
      assert {:error, :invalid_response_shape} =
               Protocol.decode_response(~s({"foo": "bar"}))
    end

    test "rejects responses with unsupported status values" do
      assert {:error, :invalid_response_shape} =
               Protocol.decode_response(~s({"id":"x","status":"running"}))
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_response} = Protocol.decode_response(:not_a_binary)
    end
  end

  describe "bounded_reason/1" do
    test "truncates long strings to 500 chars" do
      long = String.duplicate("a", 600)
      bounded = Protocol.bounded_reason(long)
      assert String.length(bounded) == 500
    end

    test "preserves short strings unchanged" do
      assert Protocol.bounded_reason("oops") == "oops"
    end

    test "formats non-binary input" do
      assert Protocol.bounded_reason(:timeout) =~ "timeout"
    end
  end
end
