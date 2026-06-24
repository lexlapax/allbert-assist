defmodule AllbertAssist.Coding.M0ContractsTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Channels.TUI.Renderer
  alias AllbertAssist.Coding.StreamEvent
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Settings.Schema

  test "stream event contract has the v0.57 M0 vocabulary and payload checks" do
    assert StreamEvent.types() == [
             :assistant_token_delta,
             :tool_call_argument_delta,
             :tool_call_argument_complete,
             :tool_result_delta,
             :turn_cancelled,
             :turn_complete
           ]

    assert {:ok, %{type: :assistant_token_delta, turn_id: "turn-1", text: "hi"}} =
             StreamEvent.new(:assistant_token_delta, %{turn_id: "turn-1", text: "hi"})

    assert {:ok, %{type: :tool_call_argument_delta, arguments_delta: "{\"path\""}} =
             StreamEvent.new(:tool_call_argument_delta, %{
               turn_id: "turn-1",
               tool_call_id: "call-1",
               arguments_delta: "{\"path\""
             })

    assert {:ok, %{type: :turn_cancelled, reason: :operator_cancelled}} =
             StreamEvent.new(:turn_cancelled, %{
               turn_id: "turn-1",
               reason: :operator_cancelled
             })

    assert {:error, {:missing_turn_id, _event}} =
             StreamEvent.new(:turn_complete, %{model_payload: "done"})

    assert {:error, {:invalid_stream_event_payload, _event}} =
             StreamEvent.new(:assistant_token_delta, %{turn_id: "turn-1"})

    assert {:error, {:unknown_stream_event_type, :future_event}} =
             StreamEvent.new(:future_event, %{turn_id: "turn-1"})
  end

  test "Settings Central knows the v0.57 coding permission keys" do
    for {key, default} <- [
          {"permissions.coding_file_read", "allowed"},
          {"permissions.coding_file_write", "needs_confirmation"},
          {"permissions.coding_shell_execute", "needs_confirmation"}
        ] do
      assert key in Schema.safe_write_keys()
      assert %{default: ^default, writable?: true, sensitive?: false} = Schema.schema()[key]
      assert :ok = Schema.validate_key_value(key, default)
    end
  end

  test "v0.55 TUI channel and static split payload substrate are present" do
    assert {:module, AllbertAssist.Channels.TUI.Adapter} =
             Code.ensure_loaded(AllbertAssist.Channels.TUI.Adapter)

    assert {:module, AllbertAssist.Channels.TUI.Renderer} =
             Code.ensure_loaded(AllbertAssist.Channels.TUI.Renderer)

    response =
      Response.normalize(%{
        model_payload: "model-clean",
        surface_payload: "surface-rendered"
      })

    assert response.model_payload == "model-clean"
    assert response.surface_payload == "surface-rendered"

    assert {:ok, ["surface-rendered"]} = Renderer.render_response(response)

    assert {:module, Owl.LiveScreen} = Code.ensure_loaded(Owl.LiveScreen)
    assert function_exported?(Owl.LiveScreen, :add_block, 2)
    assert function_exported?(Owl.LiveScreen, :update, 3)
    assert function_exported?(Owl.LiveScreen, :await_render, 1)
  end

  test "ReqLLM streaming and context APIs needed by v0.57 are available" do
    assert {:module, ReqLLM.Context} = Code.ensure_loaded(ReqLLM.Context)
    assert {:module, ReqLLM.StreamResponse} = Code.ensure_loaded(ReqLLM.StreamResponse)
    assert {:module, ReqLLM.StreamChunk} = Code.ensure_loaded(ReqLLM.StreamChunk)

    assert function_exported?(ReqLLM.Context, :merge_response, 2)
    assert function_exported?(ReqLLM.Context, :merge_response, 3)
    assert function_exported?(ReqLLM.StreamResponse, :tokens, 1)
    assert function_exported?(ReqLLM.StreamResponse, :tool_calls, 1)
    assert function_exported?(ReqLLM.StreamResponse, :process_stream, 2)
    assert function_exported?(ReqLLM.StreamChunk, :text, 2)
    assert function_exported?(ReqLLM.StreamChunk, :thinking, 2)
    assert function_exported?(ReqLLM.StreamChunk, :tool_call, 3)
    assert function_exported?(ReqLLM.StreamChunk, :meta, 2)

    assert %ReqLLM.StreamChunk{type: :content, text: "hello"} =
             ReqLLM.StreamChunk.text("hello")

    assert %ReqLLM.StreamChunk{type: :thinking, text: "hmm"} =
             ReqLLM.StreamChunk.thinking("hmm")

    assert %ReqLLM.StreamChunk{type: :tool_call, name: "read", arguments: %{path: "README.md"}} =
             ReqLLM.StreamChunk.tool_call("read", %{path: "README.md"})

    assert %ReqLLM.StreamChunk{type: :meta, metadata: %{finish_reason: "stop"}} =
             ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})

    assert MapSet.new([:stream, :metadata_handle, :cancel, :model, :context]) ==
             ReqLLM.StreamResponse.__struct__()
             |> Map.keys()
             |> Enum.reject(&(&1 == :__struct__))
             |> MapSet.new()
  end
end
