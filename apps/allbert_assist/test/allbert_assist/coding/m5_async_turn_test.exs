defmodule AllbertAssist.Coding.M5AsyncTurnTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Coding.TurnSupervisor
  alias AllbertAssist.Conversations
  alias AllbertAssist.Memory
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Trace

  setup do
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-coding-m5-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Memory, root: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    on_exit(fn ->
      restore_app_env(Runtime, original_runtime_config)
      restore_app_env(Memory, original_memory_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(Trace, original_trace_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "M5 Settings Central keys are safe writable and validate" do
    for {key, value} <- [
          {"coding.turn.supervised", true},
          {"coding.turn.max_ms", 120_000}
        ] do
      assert key in Schema.safe_write_keys()
      assert %{writable?: true, sensitive?: false} = Schema.schema()[key]
      assert :ok = Schema.validate_key_value(key, value)
    end
  end

  test "coding turn runs under a supervised addressable task" do
    parent = self()
    turn_id = unique_turn_id("addressable")

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runner_started, request})

        receive do
          :finish_turn ->
            {:ok, %{message: "supervised turn complete", status: :completed}}
        end
      end
    )

    task =
      Task.async(fn ->
        Runtime.submit_user_input(%{
          text: "run as a coding turn",
          channel: :test,
          user_id: "m5-addressable",
          new_thread: true,
          coding_turn?: true,
          coding_turn_id: turn_id
        })
      end)

    assert_receive {:runner_started, %{coding_turn?: true, coding_turn_id: ^turn_id}}, 5_000

    assert {:ok, %{pid: pid, status: :running, turn_id: ^turn_id}} =
             TurnSupervisor.lookup(turn_id)

    send(pid, :finish_turn)

    assert {:ok, response} = Task.await(task, 5_000)
    assert response.status == :completed
    assert response.message == "supervised turn complete"
    assert {:error, :not_found} = TurnSupervisor.lookup(turn_id)
  end

  test "task shutdown yields partial traced response and no orphaned turn", %{root: root} do
    parent = self()
    turn_id = unique_turn_id("shutdown")

    AllbertAssist.TraceTestSupport.enable_trace_default!()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, _request ->
        send(parent, :runner_blocked)

        receive do
          :never -> {:ok, %{message: "should not complete", status: :completed}}
        end
      end
    )

    task =
      Task.async(fn ->
        Runtime.submit_user_input(%{
          text: "stop this coding turn",
          channel: :test,
          user_id: "m5-shutdown",
          new_thread: true,
          metadata: %{coding_turn?: true, coding_turn_id: turn_id}
        })
      end)

    assert_receive :runner_blocked, 5_000
    assert {:ok, %{pid: pid}} = TurnSupervisor.lookup(turn_id)
    assert Process.alive?(pid)

    assert :ok = TurnSupervisor.shutdown(turn_id, :operator_validation)

    assert {:ok, response} = Task.await(task, 5_000)
    assert response.status == :cancelled
    assert response.message =~ "partial turn was preserved"
    assert response.trace_id =~ Path.join(root, "traces")
    assert File.exists?(response.trace_id)
    assert {:error, :not_found} = TurnSupervisor.lookup(turn_id)

    trace = File.read!(response.trace_id)
    assert trace =~ turn_id
    assert trace =~ "partial turn was preserved"

    assert {:ok, %{messages: messages}} =
             Conversations.show_thread("m5-shutdown", response.thread_id)

    assert Enum.map(messages, & &1.role) == ["user", "assistant"]
    assert List.last(messages).content =~ "partial turn was preserved"
  end

  test "turn max duration produces timed-out partial response" do
    parent = self()
    turn_id = unique_turn_id("timeout")

    assert {:ok, _setting} = Settings.put("coding.turn.max_ms", 100, %{audit?: false})

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, _request ->
        send(parent, :runner_sleeping)
        Process.sleep(10_000)
        {:ok, %{message: "too late", status: :completed}}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "time out this coding turn",
               channel: :test,
               user_id: "m5-timeout",
               new_thread: true,
               coding_turn?: true,
               coding_turn_id: turn_id
             })

    assert_receive :runner_sleeping
    assert response.status == :timed_out
    assert response.message =~ "timed out before completion"

    assert [%{source: :coding_turn, status: :timed_out, turn_id: ^turn_id}] =
             response.diagnostics

    assert {:error, :not_found} = TurnSupervisor.lookup(turn_id)
  end

  test "supervision setting false preserves synchronous turn-complete behavior" do
    parent = self()
    turn_id = unique_turn_id("sync")

    assert {:ok, _setting} = Settings.put("coding.turn.supervised", false, %{audit?: false})

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:sync_runner_called, request.coding_turn?})
        {:ok, %{message: "sync coding response", status: :completed}}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "sync fallback coding turn",
               channel: :test,
               user_id: "m5-sync",
               new_thread: true,
               coding_turn?: true,
               coding_turn_id: turn_id
             })

    assert_receive {:sync_runner_called, true}
    assert response.status == :completed
    assert response.message == "sync coding response"
    assert {:error, :not_found} = TurnSupervisor.lookup(turn_id)
  end

  defp unique_turn_id(prefix),
    do: "m5-#{prefix}-#{System.unique_integer([:positive])}"

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
