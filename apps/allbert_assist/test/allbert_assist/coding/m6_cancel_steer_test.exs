defmodule AllbertAssist.Coding.M6CancelSteerTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Channels.TUI.Adapter
  alias AllbertAssist.Coding.TurnSupervisor
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Trace

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-coding-m6-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Memory, root: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    assert {:ok, "allbert.tui"} = PluginRegistry.register_module(TUIPlugin)
    Fragments.clear_cache()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Memory, original_memory_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "M6 Settings Central keys are safe writable and validate" do
    for {key, value} <- [
          {"coding.steer.enabled", true},
          {"coding.cancel.grace_ms", 2_000}
        ] do
      assert key in Schema.safe_write_keys()
      assert %{writable?: true, sensitive?: false} = Schema.schema()[key]
      assert :ok = Schema.validate_key_value(key, value)
    end
  end

  test "cancel invokes registered stream cancel and preserves a partial traced response", %{
    root: root
  } do
    parent = self()
    turn_id = unique_turn_id("stream")

    AllbertAssist.TraceTestSupport.enable_trace_default!()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runner_started, request})

        :ok =
          TurnSupervisor.register_stream_cancel(request.coding_turn_id, fn ->
            send(parent, {:stream_cancelled, request.coding_turn_id})
          end)

        send(parent, {:stream_cancel_registered, request.coding_turn_id})

        receive do
          :finish_turn ->
            {:ok, %{message: "should not complete", status: :completed}}
        end
      end
    )

    task =
      Task.async(fn ->
        Runtime.submit_user_input(%{
          text: "cancel this streamed coding turn",
          channel: :test,
          user_id: "m6-stream",
          new_thread: true,
          coding_turn?: true,
          coding_turn_id: turn_id
        })
      end)

    assert_receive {:runner_started, %{coding_turn?: true, coding_turn_id: ^turn_id}}, 5_000
    assert_receive {:stream_cancel_registered, ^turn_id}, 5_000

    assert {:ok, %{stream_cancel: :ok, shutdown: :ok, turn_id: ^turn_id}} =
             TurnSupervisor.cancel(turn_id, :operator_escape)

    assert_receive {:stream_cancelled, ^turn_id}, 1_000

    assert {:ok, response} = Task.await(task, 5_000)
    assert response.status == :cancelled
    assert response.message =~ "partial turn was preserved"
    assert response.trace_id =~ Path.join(root, "traces")
    assert File.exists?(response.trace_id)
    assert [%{type: :turn_cancelled, turn_id: ^turn_id}] = response.stream_events
    assert response.turn_id == turn_id
    assert {:error, :not_found} = TurnSupervisor.lookup(turn_id)
  end

  test "cancel without a registered provider stream still shuts down and traces the turn", %{
    root: root
  } do
    parent = self()
    turn_id = unique_turn_id("no-stream")

    AllbertAssist.TraceTestSupport.enable_trace_default!()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runner_started_without_stream, request})

        receive do
          :finish_turn ->
            {:ok, %{message: "should not complete", status: :completed}}
        end
      end
    )

    task =
      Task.async(fn ->
        Runtime.submit_user_input(%{
          text: "cancel this non-streamed coding turn",
          channel: :test,
          user_id: "m6-no-stream",
          new_thread: true,
          coding_turn?: true,
          coding_turn_id: turn_id
        })
      end)

    assert_receive {:runner_started_without_stream,
                    %{coding_turn?: true, coding_turn_id: ^turn_id}},
                   5_000

    assert {:ok, %{stream_cancel: :not_registered, shutdown: :ok, turn_id: ^turn_id}} =
             TurnSupervisor.cancel(turn_id, :operator_escape)

    assert {:ok, response} = Task.await(task, 5_000)
    assert response.status == :cancelled
    assert response.message =~ "partial turn was preserved"
    assert response.trace_id =~ Path.join(root, "traces")
    assert File.exists?(response.trace_id)
    assert [%{type: :turn_cancelled, turn_id: ^turn_id}] = response.stream_events
    assert response.turn_id == turn_id
    assert {:error, :not_found} = TurnSupervisor.lookup(turn_id)
  end

  test "TUI coding mode queues correction and cancels running turn through registry" do
    configure_tui!()
    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runtime_request, request})

        if request.text == "long turn" do
          :ok =
            TurnSupervisor.register_stream_cancel(request.coding_turn_id, fn ->
              send(parent, {:stream_cancelled, request.text})
            end)

          receive do
            :finish_turn ->
              {:ok, %{message: "long turn complete", status: :completed}}
          end
        else
          {:ok,
           %{
             model_payload: "queued response: #{request.text}",
             surface_payload: "[surface] #{request.text}",
             status: :completed
           }}
        end
      end
    )

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               coding_mode?: true,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:accepted, turn_id}} =
             Adapter.submit(server, "long turn",
               async?: true,
               external_event_id: unique_event_id("long")
             )

    assert_receive {:runtime_request,
                    %{
                      text: "long turn",
                      coding_turn?: true,
                      coding_turn_id: ^turn_id,
                      metadata: %{surface: "pi_mode"}
                    }},
                   5_000

    assert {:ok, {:queued, ^turn_id}} =
             Adapter.submit(server, "apply queued correction",
               async?: true,
               external_event_id: unique_event_id("queued")
             )

    assert_output_contains("Queued correction for next coding turn.")

    assert {:ok, {:cancel_requested, %{stream_cancel: :ok, shutdown: :ok}}} =
             Adapter.cancel_current_turn(server)

    assert_receive {:stream_cancelled, "long turn"}, 1_000
    assert_output_contains("Turn cancelled:")

    assert_receive {:runtime_request,
                    %{
                      text: "apply queued correction",
                      coding_turn?: true,
                      metadata: %{surface: "pi_mode"}
                    }},
                   5_000

    assert_output_contains("[surface] apply queued correction")
  end

  defp configure_tui! do
    assert {:ok, _setting} = Settings.put("channels.tui.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.tui.identity_map",
               [
                 %{
                   "external_user_id" => "default",
                   "user_id" => "alice",
                   "enabled" => true
                 }
               ],
               %{audit?: false}
             )
  end

  defp assert_output_contains(text) do
    assert_receive {:tui_output, output}, 5_000
    assert output =~ text
  end

  defp unique_turn_id(prefix),
    do: "m6-#{prefix}-#{System.unique_integer([:positive])}"

  defp unique_event_id(prefix),
    do: "evt-m6-#{prefix}-#{System.unique_integer([:positive])}"

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end
end
