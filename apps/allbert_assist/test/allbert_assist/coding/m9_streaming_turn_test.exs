defmodule AllbertAssist.Coding.M9StreamingTurnTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.Coding.StreamingTurn
  alias AllbertAssist.Coding.TurnSupervisor
  alias AllbertAssist.Intent.PendingClarification
  alias AllbertAssist.Intent.Router.PendingStore
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  defmodule FakeReqLLM do
    alias ReqLLM.StreamResponse
    alias ReqLLM.StreamResponse.MetadataHandle

    def stream_text(model_spec, prompt, opts) do
      config = Application.get_env(:allbert_assist, __MODULE__, [])
      parent = Keyword.fetch!(config, :parent)
      turn_id = Keyword.fetch!(config, :turn_id)
      mode = Keyword.get(config, :mode, :two_chunk)

      send(parent, {:stream_text_called, model_spec, prompt, opts, self()})

      {:ok, metadata_handle} = MetadataHandle.start_link(fn -> metadata(mode, prompt) end)

      {:ok,
       %StreamResponse{
         stream: stream(mode, parent, prompt),
         metadata_handle: metadata_handle,
         cancel: fn ->
           send(parent, {:provider_cancelled, turn_id})
           :ok
         end,
         model: model_spec,
         context: prompt
       }}
    end

    defp stream(:two_chunk, parent, _prompt) do
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

    defp stream(:blocked, parent, _prompt) do
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

    defp stream(:tool_read, _parent, prompt) do
      if tool_result_context?(prompt) do
        [
          ReqLLM.StreamChunk.text("The file contains needle."),
          ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
        ]
      else
        [
          ReqLLM.StreamChunk.tool_call("read", %{"path" => "sample.txt", "limit" => 3}, %{
            id: "call-read"
          }),
          ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
        ]
      end
    end

    defp stream(:tool_write, _parent, prompt) do
      if tool_result_context?(prompt) do
        [
          ReqLLM.StreamChunk.text("Write is pending approval."),
          ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
        ]
      else
        [
          ReqLLM.StreamChunk.tool_call(
            "write",
            %{"path" => "pending-write.txt", "content" => "pending\n"},
            %{id: "call-write"}
          ),
          ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
        ]
      end
    end

    defp stream(:pseudo_tool_text, _parent, _prompt) do
      [
        ReqLLM.StreamChunk.text(
          "I will use the write tool.\n\n<function=write>\n<parameter=path>\ntmp/pseudo.txt\n</parameter>\n</function>\n</tool_call>"
        ),
        ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
      ]
    end

    defp stream(:tool_edit, _parent, prompt) do
      if tool_result_context?(prompt) do
        [
          ReqLLM.StreamChunk.text("Edit is pending approval."),
          ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
        ]
      else
        [
          ReqLLM.StreamChunk.tool_call(
            "edit",
            %{
              "path" => "editable.txt",
              "old_text" => "old\n",
              "new_text" => "new\n"
            },
            %{id: "call-edit"}
          ),
          ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
        ]
      end
    end

    defp stream(:tool_bash, _parent, prompt) do
      if tool_result_context?(prompt) do
        [
          ReqLLM.StreamChunk.text("Bash is pending approval."),
          ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
        ]
      else
        [
          ReqLLM.StreamChunk.tool_call(
            "bash",
            %{"executable" => "printf", "args" => ["ran"], "cwd" => "."},
            %{id: "call-bash"}
          ),
          ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
        ]
      end
    end

    defp stream(:tool_bash_command_string, _parent, prompt) do
      if tool_result_context?(prompt) do
        [
          ReqLLM.StreamChunk.text("Bash is pending approval."),
          ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
        ]
      else
        [
          ReqLLM.StreamChunk.tool_call(
            "bash",
            %{"command" => "pwd", "cwd" => "."},
            %{id: "call-bash-command-string"}
          ),
          ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
        ]
      end
    end

    defp stream(:multi_tool, _parent, prompt) do
      if tool_result_context?(prompt) do
        [
          ReqLLM.StreamChunk.text("Read and grep completed."),
          ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
        ]
      else
        [
          ReqLLM.StreamChunk.tool_call("read", %{"path" => "sample.txt", "limit" => 4}, %{
            id: "call-multi-read"
          }),
          ReqLLM.StreamChunk.tool_call(
            "grep",
            %{"pattern" => "needle", "path" => ".", "max_results" => 5},
            %{id: "call-multi-grep"}
          ),
          ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
        ]
      end
    end

    defp stream(:cwd_escape, _parent, prompt) do
      if tool_result_context?(prompt) do
        [
          ReqLLM.StreamChunk.text("Cwd escape denied."),
          ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
        ]
      else
        [
          ReqLLM.StreamChunk.tool_call("read", %{"path" => "../outside.txt"}, %{
            id: "call-cwd-escape"
          }),
          ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
        ]
      end
    end

    defp stream(:raw_shell_without_tier, _parent, prompt) do
      if tool_result_context?(prompt) do
        [
          ReqLLM.StreamChunk.text("Raw shell denied."),
          ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
        ]
      else
        [
          ReqLLM.StreamChunk.tool_call(
            "bash",
            %{"command" => "printf denied", "cwd" => "."},
            %{id: "call-raw-shell"}
          ),
          ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
        ]
      end
    end

    defp stream(:loop_limit, _parent, prompt) do
      [
        ReqLLM.StreamChunk.tool_call(
          "glob",
          %{"pattern" => "*.txt", "max_results" => 1},
          %{id: "call-loop-#{tool_result_count(prompt)}"}
        ),
        ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
      ]
    end

    defp metadata(:loop_limit, _prompt), do: %{finish_reason: :tool_calls}

    defp metadata(mode, prompt)
         when mode in [
                :tool_read,
                :tool_write,
                :tool_edit,
                :tool_bash,
                :multi_tool,
                :cwd_escape,
                :raw_shell_without_tier
              ] do
      if tool_result_context?(prompt),
        do: %{finish_reason: :stop},
        else: %{finish_reason: :tool_calls}
    end

    defp metadata(_mode, _prompt), do: %{finish_reason: :stop}

    defp tool_result_context?(%ReqLLM.Context{messages: messages}) do
      Enum.any?(messages, &(&1.role == :tool))
    end

    defp tool_result_context?(_prompt), do: false

    defp tool_result_count(%ReqLLM.Context{messages: messages}) do
      Enum.count(messages, &(&1.role == :tool))
    end

    defp tool_result_count(_prompt), do: 0
  end

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_streaming_config = Application.get_env(:allbert_assist, StreamingTurn)
    original_fake_config = Application.get_env(:allbert_assist, FakeReqLLM)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-coding-m9-#{System.unique_integer([:positive])}"
      )

    root = Path.join(home, "workspace")

    Enum.each(@env_vars, &System.delete_env/1)
    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    File.mkdir_p!(root)
    configure_settings!(root)

    Application.put_env(:allbert_assist, StreamingTurn,
      req_llm_client: FakeReqLLM,
      streaming_enabled?: true,
      model_profile_resolver: &resolve_test_model_profile/1
    )

    on_exit(fn ->
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(StreamingTurn, original_streaming_config)
      restore_app_env(FakeReqLLM, original_fake_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home, root: root}
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

    assert {:stream_text_called, %{provider: :openai, id: "qwen2.5:7b"},
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
    assert response.direct_answer.model_profile == "pi_coding_local"
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

    assert {:stream_text_called, %{provider: :openai, id: "qwen2.5:7b"}, %ReqLLM.Context{}, _opts,
            _stream_pid} = assert_stream_text_called(task, turn_id)

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

    assert {:stream_text_called, %{provider: :openai, id: "qwen2.5:7b"}, %ReqLLM.Context{}, _opts,
            stream_pid} = assert_stream_text_called(task, turn_id, 15_000)

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

  test "coding turns bypass pending clarification and registry-action overrides", %{
    root: root
  } do
    parent = self()
    turn_id = unique_turn_id("agent-pending")
    thread_id = "test-thread-#{turn_id}"
    now = DateTime.utc_now()

    :ok =
      PendingStore.put(%PendingClarification{
        thread_id: thread_id,
        user_id: "local",
        session_id: "test-session",
        question: "Read a note?",
        options: [%{kind: :action, id: "read_note", label: "read note"}],
        created_at: now,
        expires_at: DateTime.add(now, 120_000, :millisecond)
      })

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :two_chunk
    )

    request =
      root
      |> agent_request(turn_id, parent)
      |> Map.put(:text, "Read docs/plans/archives/v0.57-plan.md")

    task =
      Task.async(fn ->
        TurnSupervisor.run(turn_metadata(root, turn_id, parent), fn ->
          IntentAgent.respond(request)
        end)
      end)

    assert {:stream_text_called, %{provider: :openai, id: "qwen2.5:7b"}, %ReqLLM.Context{}, _opts,
            stream_pid} = assert_stream_text_called(task, turn_id, 15_000)

    send(stream_pid, :release_stream)

    assert {:ok, response} = Task.await(task, 5_000)
    assert response.status == :completed
    assert response.message == "Hello"
    assert response.direct_answer.source == :coding_stream
    assert [%{name: "direct_answer", status: :completed}] = response.actions
    assert {:ok, %PendingClarification{}} = PendingStore.take("local", thread_id)
  end

  test "model-proposed read tool executes through Runner and continues the stream", %{
    root: root
  } do
    File.write!(Path.join(root, "sample.txt"), "alpha\nneedle\nomega\n")

    parent = self()
    turn_id = unique_turn_id("tool-read")

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :tool_read
    )

    assert {:ok, response} =
             StreamingTurn.answer(
               "read sample.txt and summarize it",
               streaming_context(root, turn_id, parent)
             )

    assert_receive {:stream_text_called, _model, %ReqLLM.Context{} = first_prompt, first_opts,
                    _pid},
                   1_000

    assert_receive {:stream_text_called, _model, %ReqLLM.Context{} = second_prompt, second_opts,
                    _pid},
                   1_000

    assert length(Keyword.fetch!(first_opts, :tools)) == 6
    assert length(Keyword.fetch!(second_opts, :tools)) == 6
    refute Enum.any?(first_prompt.messages, &(&1.role == :tool))
    assert Enum.any?(second_prompt.messages, &(&1.role == :tool))

    assert response.status == :completed
    assert response.message == "The file contains needle."
    assert response.coding_turn.source == :req_llm_stream_tool_loop
    assert response.coding_turn.tool_call_count == 1
    assert [%{name: "read", status: :completed} | _] = response.actions
    assert %ReqLLM.Context{} = response.coding_session_context

    assert Enum.map(response.stream_events, & &1.type) == [
             :tool_call_argument_delta,
             :tool_call_argument_complete,
             :tool_result_delta,
             :assistant_token_delta,
             :turn_complete
           ]

    tool_result = Enum.find(response.stream_events, &(&1.type == :tool_result_delta))
    assert tool_result.text =~ "sample.txt"
    assert tool_result.text =~ "needle"
  end

  test "model-proposed effectful tools return pending confirmations without applying effects", %{
    root: root
  } do
    File.write!(Path.join(root, "editable.txt"), "old\n")

    for {mode, expected} <- [
          {:tool_write,
           %{
             message: "Write is pending approval.",
             action: "write",
             id: "call-write",
             status: :needs_confirmation,
             path: "pending-write.txt",
             unchanged?: fn ->
               refute File.exists?(Path.join(root, "pending-write.txt"))
             end
           }},
          {:tool_edit,
           %{
             message: "Edit is pending approval.",
             action: "edit",
             id: "call-edit",
             status: :needs_confirmation,
             path: "editable.txt",
             unchanged?: fn ->
               assert File.read!(Path.join(root, "editable.txt")) == "old\n"
             end
           }},
          {:tool_bash,
           %{
             message: "Bash is pending approval.",
             action: "bash",
             id: "call-bash",
             status: :needs_confirmation,
             path: nil,
             unchanged?: fn -> :ok end
           }},
          {:tool_bash_command_string,
           %{
             message: "Bash is pending approval.",
             action: "bash",
             id: "call-bash-command-string",
             status: :needs_confirmation,
             path: nil,
             unchanged?: fn -> :ok end
           }}
        ] do
      parent = self()
      turn_id = unique_turn_id("#{expected.action}-pending")

      Application.put_env(:allbert_assist, FakeReqLLM,
        parent: parent,
        turn_id: turn_id,
        mode: mode
      )

      assert {:ok, response} =
               StreamingTurn.answer(
                 "try #{expected.action} through the model loop",
                 streaming_context(root, turn_id, parent)
               )

      assert_receive {:stream_text_called, _model, %ReqLLM.Context{}, first_opts, _pid}, 1_000

      assert_receive {:stream_text_called, _model, %ReqLLM.Context{} = second_prompt, _opts,
                      _pid},
                     1_000

      assert length(Keyword.fetch!(first_opts, :tools)) == 6
      assert Enum.any?(second_prompt.messages, &(&1.role == :tool))

      assert response.status == expected.status
      assert response.message == expected.message
      assert response.approval_handoff
      assert response.coding_turn.tool_call_count == 1
      assert [%{name: action_name, status: :needs_confirmation} | _] = response.actions
      assert action_name == expected.action

      tool_result = Enum.find(response.stream_events, &(&1.type == :tool_result_delta))
      assert tool_result.tool_call_id == expected.id
      assert tool_result.tool_name == expected.action
      assert tool_result.text =~ "needs_confirmation"
      assert tool_result.text =~ "confirmation_id"
      refute tool_result.text =~ "exit_status"

      if expected.path do
        assert tool_result.text =~ expected.path
      end

      expected.unchanged?.()
    end
  end

  test "intent agent preserves coding tool approval handoff through direct-answer wrapper", %{
    root: root
  } do
    parent = self()
    turn_id = unique_turn_id("agent-write-handoff")

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :tool_write
    )

    request =
      root
      |> agent_request(turn_id, parent)
      |> Map.put(
        :text,
        "Create a disposable validation file pending-write.txt containing exactly pending."
      )

    assert {:ok, response} = IntentAgent.respond(request)

    assert_receive {:stream_text_called, _model, %ReqLLM.Context{}, _opts, _pid}, 1_000
    assert_receive {:stream_text_called, _model, %ReqLLM.Context{}, _opts, _pid}, 1_000

    assert response.status == :needs_confirmation
    assert %{confirmation_id: confirmation_id} = response.approval_handoff
    assert is_binary(confirmation_id)
    assert response.confirmation_id == confirmation_id
    assert get_in(response.approval_handoff, [:target_action, :action, "name"]) == "write"

    write_action = Enum.find(response.actions, &(Map.get(&1, :name) == "write"))
    assert get_in(write_action, [:approval_handoff, :confirmation_id]) == confirmation_id

    direct_answer_action = Enum.find(response.actions, &(Map.get(&1, :name) == "direct_answer"))

    refute get_in(direct_answer_action, [:approval_handoff, :target_action, :action, :name]) ==
             "direct_answer"

    refute File.exists?(Path.join(root, "pending-write.txt"))
  end

  test "textual pseudo tool calls fail without running coding tools", %{root: root} do
    parent = self()
    turn_id = unique_turn_id("pseudo-tool")

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :pseudo_tool_text
    )

    assert {:ok, response} =
             StreamingTurn.answer(
               "write tmp/pseudo.txt",
               streaming_context(root, turn_id, parent)
             )

    assert_receive {:stream_text_called, _model, %ReqLLM.Context{}, _opts, _pid}, 1_000

    assert response.status == :error
    assert response.message =~ "tool-call-looking text"
    assert response.coding_turn.tool_call_count == 0
    assert response.actions == []

    assert [%{status: :pseudo_tool_text, reason: :model_emitted_textual_tool_markup}] =
             response.diagnostics

    refute File.exists?(Path.join(root, "tmp/pseudo.txt"))
  end

  test "model-proposed multi-tool sequence executes each tool before continuing", %{
    root: root
  } do
    File.write!(Path.join(root, "sample.txt"), "alpha\nneedle\nomega\n")

    parent = self()
    turn_id = unique_turn_id("multi-tool")

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :multi_tool
    )

    assert {:ok, response} =
             StreamingTurn.answer(
               "read sample.txt and grep for needle",
               streaming_context(root, turn_id, parent)
             )

    assert_receive {:stream_text_called, _model, %ReqLLM.Context{} = first_prompt, first_opts,
                    _pid},
                   1_000

    assert_receive {:stream_text_called, _model, %ReqLLM.Context{} = second_prompt, second_opts,
                    _pid},
                   1_000

    assert length(Keyword.fetch!(first_opts, :tools)) == 6
    assert length(Keyword.fetch!(second_opts, :tools)) == 6
    refute Enum.any?(first_prompt.messages, &(&1.role == :tool))
    assert Enum.count(second_prompt.messages, &(&1.role == :tool)) == 2

    assert response.status == :completed
    assert response.message == "Read and grep completed."
    assert response.coding_turn.tool_call_count == 2
    assert Enum.map(response.coding_turn.tool_calls, & &1.name) == ["read", "grep"]
    assert Enum.map(response.coding_turn.tool_calls, & &1.status) == ["completed", "completed"]
    assert Enum.map(response.actions, & &1.name) == ["read", "grep"]

    assert [
             %{tool_call_id: "call-multi-read", tool_name: "read"} = read_result,
             %{tool_call_id: "call-multi-grep", tool_name: "grep"} = grep_result
           ] = tool_result_events(response)

    assert read_result.text =~ "sample.txt"
    assert read_result.text =~ "needle"
    assert grep_result.text =~ "matches=1"
    assert grep_result.text =~ "sample.txt"
  end

  test "model-proposed cwd escape returns a denied tool result without reading outside jail", %{
    root: root
  } do
    File.write!(Path.join(Path.dirname(root), "outside.txt"), "secret outside\n")

    parent = self()
    turn_id = unique_turn_id("cwd-escape")

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :cwd_escape
    )

    assert {:ok, response} =
             StreamingTurn.answer(
               "read the file outside this repo",
               streaming_context(root, turn_id, parent)
             )

    assert_receive {:stream_text_called, _model, %ReqLLM.Context{}, _opts, _pid}, 1_000

    assert_receive {:stream_text_called, _model, %ReqLLM.Context{} = second_prompt, _opts, _pid},
                   1_000

    assert Enum.any?(second_prompt.messages, &(&1.role == :tool))
    assert response.status == :completed
    assert response.message == "Cwd escape denied."
    assert response.coding_turn.tool_call_count == 1
    assert [%{name: "read", status: :denied} | _] = response.actions

    assert [%{tool_call_id: "call-cwd-escape", tool_name: "read"} = tool_result] =
             tool_result_events(response)

    assert tool_result.text =~ "\"status\":\"denied\""
    assert tool_result.text =~ "path_outside_cwd_jail"
    refute tool_result.text =~ "secret outside"
  end

  test "model-proposed raw shell without local-coding tier returns a denied tool result", %{
    root: root
  } do
    assert {:ok, _setting} = Settings.put("coding.bash.allow_raw_shell", true, %{audit?: false})

    parent = self()
    turn_id = unique_turn_id("raw-shell")

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :raw_shell_without_tier
    )

    assert {:ok, response} =
             StreamingTurn.answer(
               "run this raw shell command",
               streaming_context_without_tier(root, turn_id, parent)
             )

    assert_receive {:stream_text_called, _model, %ReqLLM.Context{}, _opts, _pid}, 1_000

    assert_receive {:stream_text_called, _model, %ReqLLM.Context{} = second_prompt, _opts, _pid},
                   1_000

    assert Enum.any?(second_prompt.messages, &(&1.role == :tool))
    assert response.status == :completed
    assert response.message == "Raw shell denied."
    assert response.coding_turn.tool_call_count == 1
    assert [%{name: "bash", status: :denied} | _] = response.actions

    assert [%{tool_call_id: "call-raw-shell", tool_name: "bash"} = tool_result] =
             tool_result_events(response)

    assert tool_result.text =~ "\"status\":\"denied\""
    assert tool_result.text =~ "local_coding_operator_required"
    refute tool_result.text =~ "exit_status"
  end

  test "model-proposed tools stop at the max tool iteration limit", %{root: root} do
    File.write!(Path.join(root, "sample.txt"), "loop\n")

    parent = self()
    turn_id = unique_turn_id("loop-limit")

    Application.put_env(:allbert_assist, FakeReqLLM,
      parent: parent,
      turn_id: turn_id,
      mode: :loop_limit
    )

    assert {:error, {:coding_tool_loop_limit_exceeded, ^turn_id, 8}} =
             StreamingTurn.answer(
               "keep calling tools forever",
               streaming_context(root, turn_id, parent)
             )

    for expected_tool_messages <- 0..7 do
      assert_receive {:stream_text_called, _model, %ReqLLM.Context{} = prompt, opts, _pid}, 1_000
      assert length(Keyword.fetch!(opts, :tools)) == 6
      assert Enum.count(prompt.messages, &(&1.role == :tool)) == expected_tool_messages
    end

    refute_receive {:stream_text_called, _model, _prompt, _opts, _pid}, 50
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
        session: %{main?: true},
        metadata: %{
          surface: "pi_mode",
          coding: %{
            cwd_jail: root,
            workspace_root: root,
            pi_mode_enabled: true,
            trusted_operator_id: "local",
            model_profile: "pi_coding_local"
          }
        }
      }
    }
  end

  defp streaming_context_without_tier(root, turn_id, sink) do
    put_in(
      streaming_context(root, turn_id, sink),
      [
        :request,
        :metadata,
        :coding,
        :trusted_operator_id
      ],
      "someone-else"
    )
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
      session: %{main?: true},
      metadata: %{
        surface: "pi_mode",
        coding: %{
          cwd_jail: root,
          workspace_root: root,
          pi_mode_enabled: true,
          trusted_operator_id: "local",
          model_profile: "pi_coding_local"
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

  defp tool_result_events(response) do
    Enum.filter(response.stream_events, &(&1.type == :tool_result_delta))
  end

  defp resolve_test_model_profile("pi_coding_local") do
    {:ok,
     %{
       name: "pi_coding_local",
       provider: "local_ollama",
       provider_type: "openai_compatible",
       model: "qwen2.5:7b",
       temperature: 0.2,
       max_tokens: 2_000,
       timeout_ms: 120_000
     }}
  end

  defp resolve_test_model_profile(profile), do: {:error, {:unknown_profile, profile}}

  defp configure_settings!(root) do
    settings = %{
      "execution" => %{
        "local" => %{
          "enabled" => true,
          "allowed_roots" => [root],
          "allowed_commands" => ["pwd", "printf"],
          "env_allowlist" => [],
          "max_timeout_ms" => 1_000,
          "max_output_bytes" => 2_000
        }
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

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

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
