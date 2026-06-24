defmodule AllbertAssist.Coding.M9StreamingTurnTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Coding.StreamingTurn
  alias AllbertAssist.Coding.TurnSupervisor
  alias AllbertAssist.Agents.IntentAgent

  defmodule FakeReqLLM do
    def stream_text(model_spec, prompt, opts) do
      config = Application.get_env(:allbert_assist, __MODULE__, [])
      parent = Keyword.fetch!(config, :parent)
      turn_id = Keyword.fetch!(config, :turn_id)
      mode = Keyword.get(config, :mode, :two_chunk)

      send(parent, {:stream_text_called, model_spec, prompt, opts, self()})

      {:ok,
       %ReqLLM.StreamResponse{
         stream: stream(mode, parent),
         metadata_handle: nil,
         cancel: fn ->
           send(parent, {:provider_cancelled, turn_id})
           :ok
         end,
         model: model_spec,
         context: ReqLLM.Context.new([])
       }}
    end

    defp stream(:two_chunk, parent) do
      Stream.resource(
        fn -> 0 end,
        fn
          0 ->
            {[ReqLLM.StreamChunk.text("Hel")], 1}

          1 ->
            send(parent, {:stream_waiting, self()})

            receive do
              :release_stream -> {[ReqLLM.StreamChunk.text("lo")], 2}
            after
              5_000 -> {[], 2}
            end

          2 ->
            {:halt, 2}
        end,
        fn _state -> :ok end
      )
    end

    defp stream(:blocked, parent) do
      Stream.resource(
        fn -> :start end,
        fn
          :start ->
            send(parent, {:blocked_stream_started, self()})

            receive do
              :release_stream -> {[ReqLLM.StreamChunk.text("late")], :done}
            after
              10_000 -> {[], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn _state -> :ok end
      )
    end
  end

  setup do
    original_streaming_config = Application.get_env(:allbert_assist, StreamingTurn)
    original_fake_config = Application.get_env(:allbert_assist, FakeReqLLM)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-coding-m9-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, StreamingTurn,
      req_llm_client: FakeReqLLM,
      streaming_enabled?: true,
      model_profile_resolver: &resolve_test_model_profile/1
    )

    on_exit(fn ->
      restore_app_env(StreamingTurn, original_streaming_config)
      restore_app_env(FakeReqLLM, original_fake_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "coding turn opens a ReqLLM stream and emits assistant deltas before completion", %{
    root: root
  } do
    parent = self()
    turn_id = unique_turn_id("stream")

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :two_chunk
    )

    task =
      Task.async(fn ->
        TurnSupervisor.run(turn_metadata(root, turn_id, parent), fn ->
          StreamingTurn.answer("stream a short answer", streaming_context(root, turn_id, parent))
        end)
      end)

    assert {:stream_text_called, %{provider: :openai, id: "qwen2.5-coder:7b"},
            %ReqLLM.Context{} = prompt, opts, stream_pid} =
             assert_stream_text_called(task, turn_id)

    assert context_text(prompt) =~ "Operator request:"
    assert Keyword.fetch!(opts, :max_tokens) >= 2_000

    assert_receive {:coding_stream_event, ^turn_id, %{type: :assistant_token_delta, text: "Hel"}},
                   1_000

    assert_receive {:stream_waiting, ^stream_pid}, 1_000
    refute Task.yield(task, 20)

    send(stream_pid, :release_stream)

    assert_receive {:coding_stream_event, ^turn_id, %{type: :assistant_token_delta, text: "lo"}},
                   1_000

    assert_receive {:coding_stream_event, ^turn_id,
                    %{type: :turn_complete, surface_payload: "Hello"}},
                   1_000

    assert {:ok, response} = Task.await(task, 5_000)
    assert response.status == :completed
    assert response.message == "Hello"
    assert response.direct_answer.source == :coding_stream
    assert response.direct_answer.model_profile == "coding_local"
    assert response.turn_id == turn_id

    assert Enum.map(response.stream_events, & &1.type) == [
             :assistant_token_delta,
             :assistant_token_delta,
             :turn_complete
           ]
  end

  test "Esc cancellation invokes the live provider stream cancel callback", %{root: root} do
    parent = self()
    turn_id = unique_turn_id("cancel")

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :blocked
    )

    task =
      Task.async(fn ->
        TurnSupervisor.run(turn_metadata(root, turn_id, parent), fn ->
          StreamingTurn.answer("stream a short answer", streaming_context(root, turn_id, parent))
        end)
      end)

    assert {:stream_text_called, %{provider: :openai, id: "qwen2.5-coder:7b"}, %ReqLLM.Context{},
            _opts, _stream_pid} = assert_stream_text_called(task, turn_id)

    assert_stream_cancel_registered(turn_id)

    assert {:ok, %{stream_cancel: :ok, shutdown: :ok, turn_id: ^turn_id}} =
             TurnSupervisor.cancel(turn_id, :operator_escape, grace_ms: 100)

    assert_receive {:provider_cancelled, ^turn_id}, 1_000

    assert {:ok, response} = Task.await(task, 5_000)
    assert response.status == :cancelled
    assert response.turn_id == turn_id
    assert [%{type: :turn_cancelled, turn_id: ^turn_id}] = response.stream_events
  end

  test "coding turns route through the intent agent into the live streaming answer path", %{
    root: root
  } do
    parent = self()
    turn_id = unique_turn_id("agent")

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :two_chunk
    )

    task =
      Task.async(fn ->
        TurnSupervisor.run(turn_metadata(root, turn_id, parent), fn ->
          IntentAgent.respond(agent_request(root, turn_id, parent))
        end)
      end)

    assert {:stream_text_called, %{provider: :openai, id: "qwen2.5-coder:7b"}, %ReqLLM.Context{},
            _opts, stream_pid} = assert_stream_text_called(task, turn_id, 15_000)

    assert_receive {:coding_stream_event, ^turn_id, %{type: :assistant_token_delta, text: "Hel"}},
                   1_000

    assert_receive {:stream_waiting, ^stream_pid}, 1_000
    refute Task.yield(task, 20)
    send(stream_pid, :release_stream)

    assert_receive {:coding_stream_event, ^turn_id,
                    %{type: :turn_complete, surface_payload: "Hello"}},
                   1_000

    assert {:ok, response} = Task.await(task, 5_000)
    assert response.status == :completed
    assert response.message == "Hello"
    assert response.direct_answer.source == :coding_stream
    assert [%{name: "direct_answer", status: :completed}] = response.actions
  end

  defp streaming_context(root, turn_id, sink) do
    %{
      request: %{
        channel: "tui",
        user_id: "local",
        operator_id: "local",
        coding_turn?: true,
        coding_turn_id: turn_id,
        stream_event_sink: sink,
        metadata: %{
          surface: "pi_mode",
          coding: %{
            cwd_jail: root,
            workspace_root: root,
            pi_mode_enabled: true,
            model_profile: "coding_local"
          }
        }
      }
    }
  end

  defp agent_request(root, turn_id, sink) do
    %{
      text: "stream a short answer",
      channel: :tui,
      user_id: "local",
      operator_id: "local",
      thread_id: "test-thread-#{turn_id}",
      session_id: "test-session",
      coding_turn?: true,
      coding_turn_id: turn_id,
      stream_event_sink: sink,
      metadata: %{
        surface: "pi_mode",
        coding: %{
          cwd_jail: root,
          workspace_root: root,
          pi_mode_enabled: true,
          model_profile: "coding_local"
        }
      }
    }
  end

  defp turn_metadata(root, turn_id, sink) do
    %{
      turn_id: turn_id,
      input_signal_id: "test-input-#{turn_id}",
      user_id: "local",
      operator_id: "local",
      thread_id: "test-thread-#{turn_id}",
      session_id: "test-session",
      channel: "tui",
      cwd_jail: root,
      stream_event_sink: sink
    }
  end

  defp context_text(%ReqLLM.Context{messages: messages}) do
    messages
    |> Enum.flat_map(& &1.content)
    |> Enum.map_join("\n", &(&1.text || ""))
  end

  defp resolve_test_model_profile("coding_local") do
    {:ok,
     %{
       name: "coding_local",
       provider: "local_ollama",
       provider_type: "openai_compatible",
       model: "qwen2.5-coder:7b",
       temperature: 0.2,
       max_tokens: 2_000,
       timeout_ms: 120_000
     }}
  end

  defp resolve_test_model_profile(profile), do: {:error, {:unknown_profile, profile}}

  defp assert_stream_text_called(task, turn_id, timeout \\ 5_000) do
    receive do
      {:stream_text_called, _model_spec, _prompt, _opts, _stream_pid} = message ->
        message
    after
      timeout ->
        turn_stack =
          case TurnSupervisor.lookup(turn_id) do
            {:ok, %{pid: pid}} -> Process.info(pid, :current_stacktrace)
            other -> other
          end

        flunk("""
        expected stream_text call, task state=#{inspect(Task.yield(task, 0))}
        task_stack=#{inspect(Process.info(task.pid, :current_stacktrace), pretty: true)}
        turn_stack=#{inspect(turn_stack, pretty: true)}
        """)
    end
  end

  defp assert_stream_cancel_registered(turn_id, attempts \\ 20)

  defp assert_stream_cancel_registered(turn_id, attempts) when attempts > 0 do
    case TurnSupervisor.lookup(turn_id) do
      {:ok, %{stream_cancel: %{source: :req_llm_stream}}} ->
        :ok

      _other ->
        Process.sleep(25)
        assert_stream_cancel_registered(turn_id, attempts - 1)
    end
  end

  defp assert_stream_cancel_registered(turn_id, 0) do
    flunk("expected stream cancel to be registered for #{turn_id}")
  end

  defp unique_turn_id(prefix),
    do: "m9-#{prefix}-#{System.unique_integer([:positive])}"

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
