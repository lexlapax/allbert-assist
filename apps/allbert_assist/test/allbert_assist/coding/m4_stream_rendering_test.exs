defmodule AllbertAssist.Coding.M4StreamRenderingTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Channels.TUI.LiveRegion
  alias AllbertAssist.Channels.TUI.Renderer
  alias AllbertAssist.Coding.StreamEvent
  alias AllbertAssist.Coding.StreamPipeline
  alias AllbertAssist.Coding.StreamRenderer
  alias AllbertAssist.Settings.Schema

  defmodule FakeLiveScreen do
    def add_block(pid, block_id, opts) do
      send(pid, {:add_block, block_id, opts})
      :ok
    end

    def update(pid, block_id, content) do
      send(pid, {:update, block_id, content})
      :ok
    end

    def await_render(pid) do
      send(pid, :await_render)
      :ok
    end

    def flush(pid) do
      send(pid, :flush)
      :ok
    end
  end

  test "M4 Settings Central keys are safe writable and validate" do
    for {key, value} <- [
          {"coding.streaming.enabled", true},
          {"coding.streaming.turn_complete_fallback", true}
        ] do
      assert key in Schema.safe_write_keys()
      assert %{writable?: true, sensitive?: false} = Schema.schema()[key]
      assert :ok = Schema.validate_key_value(key, value)
    end
  end

  test "stream pipeline converts ReqLLM chunks into ordered stream events" do
    chunks = [
      ReqLLM.StreamChunk.text("Hel"),
      ReqLLM.StreamChunk.text("lo"),
      ReqLLM.StreamChunk.tool_call("write", %{"path" => "lib/example.ex"}, %{
        "id" => "call-1"
      }),
      ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
    ]

    assert {:ok, events} = StreamPipeline.events_from_chunks(chunks, turn_id: "turn-1")

    assert Enum.map(events, & &1.type) == [
             :assistant_token_delta,
             :assistant_token_delta,
             :tool_call_argument_delta
           ]

    assert Enum.map(events, & &1.sequence) == [0, 1, 2]
    assert [first, second, tool] = events
    assert first.text == "Hel"
    assert second.text == "lo"
    assert tool.tool_call_id == "call-1"
    assert tool.tool_name == "write"
    assert tool.arguments_delta == %{"path" => "lib/example.ex"}
  end

  test "stream renderer accumulates deltas and reconciles to final surface payload" do
    assert {:ok, text_event} =
             StreamEvent.new(:assistant_token_delta, %{turn_id: "turn-1", text: "Working"})

    assert {:ok, tool_event} =
             StreamEvent.new(:tool_call_argument_delta, %{
               turn_id: "turn-1",
               tool_call_id: "call-1",
               tool_name: "edit",
               arguments_delta: %{"path" => "lib/example.ex"}
             })

    assert {:ok, complete_event} =
             StreamPipeline.turn_complete_event(
               %{
                 status: :completed,
                 model_payload: "model-clean",
                 surface_payload: "surface diff"
               },
               turn_id: "turn-1"
             )

    assert {:ok, state} =
             "turn-1"
             |> StreamRenderer.new()
             |> StreamRenderer.apply_events([text_event, tool_event])

    live_render = StreamRenderer.render(state)
    assert live_render =~ "Working"
    assert live_render =~ "Tool call edit"
    assert live_render =~ "lib/example.ex"

    assert {:ok, final_state} = StreamRenderer.apply_event(state, complete_event)
    assert StreamRenderer.render(final_state) == "surface diff"
    refute StreamRenderer.render(final_state) =~ "model-clean"

    assert {:ok, ["surface diff"]} =
             Renderer.render_response(%{
               turn_id: "turn-1",
               stream_events: [text_event, tool_event, complete_event],
               model_payload: "model-clean",
               surface_payload: "surface diff"
             })

    assert {:ok, ["static surface"]} =
             Renderer.render_response(%{
               turn_id: "turn-1",
               stream_events: [],
               model_payload: "model-clean",
               surface_payload: "static surface"
             })
  end

  test "TUI live region updates and clears an Owl-compatible block" do
    assert {:ok, live_region} =
             LiveRegion.start(self(), "turn-1",
               screen_module: FakeLiveScreen,
               block_id: :test_coding_stream
             )

    assert_received {:add_block, :test_coding_stream, _opts}
    assert_received {:update, :test_coding_stream, ""}
    assert_received :await_render

    assert {:ok, event} =
             StreamEvent.new(:assistant_token_delta, %{turn_id: "turn-1", text: "hello"})

    assert {:ok, live_region} = LiveRegion.apply_event(live_region, event)
    assert_received {:update, :test_coding_stream, "hello"}
    assert_received :await_render

    assert {:ok, _cleared} = LiveRegion.clear(live_region)
    assert_received {:update, :test_coding_stream, []}
    assert_received :await_render
    assert_received :flush
  end
end
