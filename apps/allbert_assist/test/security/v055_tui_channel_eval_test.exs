defmodule AllbertAssist.Security.V055TUIChannelEvalTest do
  # v1.0.2 M1 lane reconciliation: exactly one primary lane. This eval file is
  # DB-backed and mutates app env + global registries, but the strongest
  # resource class is the security-eval release lane; the DB/app-env/global
  # blockers are secondary (recorded in the inventory, not as primary tags).
  use AllbertAssist.DataCase, async: false, lane: :security_eval_serial

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.ChannelParity
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.Matrix.Adapter, as: MatrixAdapter
  alias AllbertAssist.Channels.TUI.Adapter, as: TUIAdapter
  alias AllbertAssist.Channels.TUI.Renderer, as: TUIRenderer
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.TestSupport.ShippedRegistries
  alias AllbertAssist.Trace

  @eval_groups [
    parity: [
      "channel-parity-matrix-matches-descriptors-001",
      "matrix-generic-outbound-parity-001"
    ],
    tui_runtime: [
      "tui-inbound-turn-dedupe-001",
      "tui-identity-map-001",
      "tui-no-authority-001",
      "tui-redaction-001"
    ],
    tui_supervision: [
      "tui-crash-isolation-001"
    ],
    approvals: [
      "approval-primitive-honor-tui-001",
      "tui-confirmation-resolve-001"
    ],
    split_payload: [
      "split-payload-contract-001",
      "split-payload-defaulting-001",
      "tui-owl-runtime-dep-001"
    ]
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    parent = self()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v055-tui-channel-eval-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.delete_env(:allbert_assist, Trace)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runtime_request, request})

        {:ok,
         %{
           model_payload: "v0.55 model: #{request.text}",
           surface_payload: "[surface] #{request.text}",
           status: :completed
         }}
      end
    )

    PluginRegistry.clear()
    register_channel_plugins!()
    Fragments.clear_cache()
    configure_tui!()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      ShippedRegistries.restore!()
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "v0.55 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v055)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.surface == :channel_pack))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "parity matrix is descriptor-derived and Matrix generic outbound is implemented" do
    assert_eval_group!(:parity)

    assert :ok = ChannelParity.verify()
    rows = ChannelParity.matrix()

    assert %{
             provider: "terminal",
             kind: :registered_channel,
             primitives: [:typed_command, :list],
             threading: :rich,
             identity_mapping: "channels.tui.identity_map",
             approval_rendering: "typed_command+list",
             streaming: "turn_complete",
             outbound: "none"
           } = row!(rows, "tui")

    assert %{outbound: "implemented"} = row!(rows, "matrix")
    assert function_exported?(MatrixAdapter, :deliver_outbound, 3)
  end

  test "TUI input dedupes terminal turns, requires identity, redacts events, and grants no authority" do
    assert_eval_group!(:tui_runtime)

    assert {:ok, server} = start_tui_adapter()

    assert {:ok, {:processed, event, ["[surface] hello tui"]}} =
             TUIAdapter.submit(server, " hello tui ", external_event_id: "evt-v055-dedupe")

    assert_receive {:runtime_request, request}
    assert event.status == "processed"
    assert request.channel == "tui"
    assert request.user_id == "alice"
    assert request.operator_id == "alice"
    assert request.metadata.inbound_trust.permission == :channel_message_inbound
    assert request.metadata.inbound_trust.decision == :needs_confirmation
    assert request.metadata.provider == "terminal"
    assert request.active_app == :allbert
    refute Map.has_key?(request.metadata, :resource_authority)
    refute Map.has_key?(request.metadata, :active_app)

    assert {:ok, :duplicate} =
             TUIAdapter.submit(server, "hello again", external_event_id: "evt-v055-dedupe")

    refute_received {:runtime_request, _request}

    assert {:ok, _setting} = Settings.put("channels.tui.identity_map", [], %{audit?: false})
    assert {:ok, unmapped} = start_tui_adapter()

    assert {:ok, :rejected} =
             TUIAdapter.submit(unmapped, "hello tui", external_event_id: "evt-v055-unmapped")

    refute_received {:runtime_request, _request}

    rejected = Repo.get_by!(Event, channel: "tui", external_event_id: "evt-v055-unmapped")
    assert rejected.status == "rejected"
    assert rejected.reason == ":not_mapped"

    assert {:ok, redacted} =
             Channels.create_event(%{
               channel: "tui",
               provider: "terminal",
               external_event_id: "evt-v055-redact",
               external_user_id: "+15551234567",
               external_chat_id: "terminal +15557654321",
               external_message_id: "msg:+442071838750",
               payload_summary: "operator typed api_key=sk-test-1234567890 and phone +15551234567"
             })

    stored =
      inspect(
        Map.take(redacted, [
          :external_user_id,
          :external_chat_id,
          :external_message_id,
          :payload_summary
        ])
      )

    refute stored =~ "+15551234567"
    refute stored =~ "+15557654321"
    refute stored =~ "+442071838750"
    refute stored =~ "sk-test-1234567890"
    assert byte_size(redacted.payload_summary) <= 4_096
  end

  test "TUI adapter is supervised with one-for-one crash isolation" do
    assert_eval_group!(:tui_supervision)

    tui_child =
      tui_descriptor_child_spec!(
        name: nil,
        enabled?: true,
        auto_input?: false,
        live_screen?: false,
        output_fun: fn _line -> :ok end,
        restart: :transient
      )

    sibling_child =
      Supervisor.child_spec({Agent, fn -> :sibling_alive end}, id: :sibling)

    assert {:ok, supervisor} =
             Supervisor.start_link([tui_child, sibling_child], strategy: :one_for_one)

    old_tui_pid = child_pid!(supervisor, "tui")
    sibling_pid = child_pid!(supervisor, :sibling)
    launcher = Task.async(fn -> TUIAdapter.run_supervised_forever(supervisor) end)

    Process.exit(old_tui_pid, :kill)
    new_tui_pid = eventually_child_pid!(supervisor, "tui", old_tui_pid)

    assert Process.alive?(sibling_pid)
    assert Process.alive?(new_tui_pid)
    refute new_tui_pid == old_tui_pid
    assert nil == Task.yield(launcher, 50)

    GenServer.stop(new_tui_pid, :normal)
    assert :normal == Task.await(launcher, 1_000)
  end

  # v1.0.1 M4.1C: a :transient child that exited :normal before the launcher
  # attached is kept by the supervisor as {"tui", :undefined, ...}; the launcher
  # must read that as a finished session, not :tui_child_not_started.
  test "run_supervised_forever treats a completed transient tui child as a finished session" do
    assert_eval_group!(:tui_supervision)

    tui_child =
      tui_descriptor_child_spec!(
        name: nil,
        enabled?: true,
        auto_input?: false,
        live_screen?: false,
        output_fun: fn _line -> :ok end,
        restart: :transient
      )

    assert {:ok, supervisor} = Supervisor.start_link([tui_child], strategy: :one_for_one)

    pid = child_pid!(supervisor, "tui")
    GenServer.stop(pid, :normal)

    assert :normal == TUIAdapter.run_supervised_forever(supervisor)
  end

  # v1.0.1 M4.1B: raw-terminal init failure (e.g. :enotsup with no TTY) must
  # degrade to line input — the driver starts UNLINKED, so its init {:stop, ...}
  # cannot kill the adapter and abort the whole app boot.
  test "raw-terminal init failure degrades to line input instead of killing the adapter" do
    assert_eval_group!(:tui_supervision)

    parent = self()

    tui_child =
      tui_descriptor_child_spec!(
        name: nil,
        enabled?: true,
        auto_input?: true,
        emit_banner?: false,
        escape_monitor?: false,
        live_screen?: false,
        output_fun: fn line -> send(parent, {:tui_output, line}) end,
        input_driver?: true,
        input_driver_opts: [enable_raw: fn -> {:error, :enotsup} end],
        input_fun: fn _prompt -> :eof end,
        restart: :transient
      )

    assert {:ok, supervisor} = Supervisor.start_link([tui_child], strategy: :one_for_one)

    assert_receive {:tui_output, fallback_line}, 2_000
    assert fallback_line =~ "Falling back to line input"

    # The line-mode loop then reads :eof (closed stdin) and finishes the session
    # normally instead of re-prompting forever.
    assert :normal == TUIAdapter.run_supervised_forever(supervisor)
  end

  test "TUI approval rendering honors typed-command/list primitives and same-channel resolution" do
    assert_eval_group!(:approvals)

    handoff = %{
      confirmation_id: "conf_v055_render",
      status: :pending,
      target_action: %{action: %{name: "write_note"}},
      allowed_actions: [:approve, :deny, :details]
    }

    assert {:ok, [rendered]} = TUIRenderer.render_response(%{approval_handoff: handoff})
    assert rendered =~ "Type one exact command:"
    assert rendered =~ "ALLBERT:APPROVE:conf_v055_render"
    assert rendered =~ "Approval options:"
    assert rendered =~ "1. Approve - ALLBERT:APPROVE:conf_v055_render"
    refute rendered =~ "allbert:v1:"
    refute rendered =~ "http"

    assert {:ok, same_channel} = create_confirmation!("conf_v055_same_channel", "tui")
    assert {:ok, server} = start_tui_adapter()

    assert {:ok, {:processed, event, [callback_rendered]}} =
             TUIAdapter.submit(server, "ALLBERT:DENY:#{same_channel["id"]}",
               external_event_id: "evt-v055-callback"
             )

    refute_received {:runtime_request, %{text: "ALLBERT:DENY:" <> _rest}}
    assert event.direction == "callback"
    assert event.status == "processed"
    assert callback_rendered =~ "denied"

    assert {:ok, denied} = Confirmations.read(same_channel["id"])
    assert denied["status"] == "denied"
    assert denied["operator_resolution"]["resolver_actor"] == "alice"
    assert denied["operator_resolution"]["resolver_channel"] == "tui"

    assert {:ok, wrong_channel} = create_confirmation!("conf_v055_wrong_channel", "slack")

    assert {:ok, :rejected} =
             TUIAdapter.submit(server, "ALLBERT:DENY:#{wrong_channel["id"]}",
               external_event_id: "evt-v055-wrong-channel"
             )

    assert {:ok, pending} = Confirmations.read(wrong_channel["id"])
    assert pending["status"] == "pending"

    rejected =
      Repo.get_by!(Event, channel: "tui", external_event_id: "evt-v055-wrong-channel")

    assert rejected.direction == "callback"
    assert rejected.status == "rejected"
    assert rejected.reason == ":wrong_channel"
  end

  test "split payloads persist model text, render surface text, and Owl is a runtime dependency" do
    assert_eval_group!(:split_payload)

    legacy = Response.normalize(%{message: "legacy same text"})
    assert legacy.message == "legacy same text"
    assert legacy.model_payload == "legacy same text"
    assert legacy.surface_payload == "legacy same text"

    split =
      Response.normalize(%{
        model_payload: "model clean",
        surface_payload: IO.ANSI.green() <> "surface decorated" <> IO.ANSI.reset(),
        status: :completed
      })

    assert split.message == "model clean"
    assert split.model_payload == "model clean"
    assert split.surface_payload =~ "surface decorated"

    assert {:ok, server} = start_tui_adapter()

    assert {:ok, {:processed, event, ["[surface] split payload"]}} =
             TUIAdapter.submit(server, "split payload", external_event_id: "evt-v055-split")

    assert_receive {:runtime_request, request}
    assert {:ok, %{messages: messages}} = Conversations.show_thread("alice", request.thread_id)
    assert event.thread_id == request.thread_id

    # v1.0.2 M1 residue (b): the runtime reuses the user's most recent general
    # thread with no recency window, so this thread can carry rows committed by
    # earlier runs of other suites against the shared SQLite test file.
    # Assert on THIS turn's user/assistant tail instead of absolute positions.
    assert [
             %{role: "user", content: "split payload"},
             %{role: "assistant", content: assistant_content}
           ] = Enum.take(messages, -2)

    assert assistant_content == "v0.55 model: split payload"
    refute assistant_content =~ "[surface]"

    assert {:module, Owl.Data} = Code.ensure_loaded(Owl.Data)
    assert {:module, Owl.LiveScreen} = Code.ensure_loaded(Owl.LiveScreen)

    apps = Application.spec(:allbert_assist, :applications)
    assert :owl in apps
  end

  defp register_channel_plugins! do
    modules = [
      AllbertAssist.Plugins.Telegram,
      AllbertAssist.Plugins.Email,
      AllbertAssist.Plugins.Discord,
      AllbertAssist.Plugins.Slack,
      AllbertAssist.Plugins.Matrix,
      AllbertAssist.Plugins.WhatsApp,
      AllbertAssist.Plugins.Signal,
      AllbertAssist.Plugins.TUI
    ]

    Enum.each(modules, fn module ->
      assert {:ok, _plugin_id} = PluginRegistry.register_module(module)
    end)
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

  defp start_tui_adapter(opts \\ []) do
    TUIAdapter.start_link(
      Keyword.merge(
        [
          name: nil,
          auto_input?: false,
          enabled?: true,
          live_screen?: false,
          output_fun: fn _line -> :ok end
        ],
        opts
      )
    )
  end

  defp create_confirmation!(id, channel) do
    Confirmations.create(%{
      id: id,
      origin: %{actor: "alice", channel: channel, surface: "v055-eval"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    })
  end

  defp row!(rows, channel) do
    Enum.find(rows, &(&1.channel == channel)) || flunk("missing parity row #{channel}")
  end

  defp tui_descriptor_child_spec!(opts) do
    Channels.channel_child_specs(channel_child_opts: %{"tui" => opts})
    |> Enum.find_value(fn
      %{id: "tui"} = child -> child
      _child -> nil
    end)
    |> case do
      nil -> flunk("missing descriptor-derived tui child spec")
      child -> child
    end
  end

  defp child_pid!(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
    |> case do
      nil -> flunk("missing child #{inspect(child_id)}")
      pid -> pid
    end
  end

  defp eventually_child_pid!(supervisor, child_id, old_pid, attempts \\ 20)

  defp eventually_child_pid!(_supervisor, child_id, _old_pid, 0),
    do: flunk("child #{inspect(child_id)} was not restarted")

  defp eventually_child_pid!(supervisor, child_id, old_pid, attempts) do
    pid = child_pid!(supervisor, child_id)

    if pid != old_pid and Process.alive?(pid) do
      pid
    else
      Process.sleep(20)
      eventually_child_pid!(supervisor, child_id, old_pid, attempts - 1)
    end
  end

  defp assert_eval_group!(group) do
    ids = Keyword.fetch!(@eval_groups, group)
    milestone_rows = EvalInventory.rows_for_milestone(:v055)
    rows = Enum.map(ids, &find_eval_row!(milestone_rows, &1))

    assert Enum.map(rows, & &1.id) == ids
    assert Enum.all?(rows, &(&1.milestone == :v055))
    assert Enum.all?(rows, &(&1.surface == :channel_pack))
  end

  defp find_eval_row!(rows, id) do
    Enum.find(rows, &(&1.id == id)) || flunk("missing v0.55 eval row #{id}")
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
