defmodule AllbertAssist.Channels.TUITest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.TUI.Adapter
  alias AllbertAssist.Channels.TUI.Renderer
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Trace

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-tui-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    assert {:ok, "allbert.tui"} = PluginRegistry.register_module(TUIPlugin)
    Fragments.clear_cache()

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})

        {:ok,
         %{
           model_payload: "Clean TUI response: #{request.text}",
           surface_payload: "[surface] #{request.text}",
           status: :completed
         }}
      end
    )

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "plugin descriptor declares local terminal channel contract" do
    assert [descriptor] = TUIPlugin.channels()

    assert descriptor.channel_id == "tui"
    assert descriptor.provider == "terminal"
    assert descriptor.primitives == [:typed_command, :list]
    assert descriptor.threading == :rich
    assert descriptor.trust_class == :local
    assert descriptor.settings_prefix == "channels.tui"
    assert descriptor.identity_map_key == "channels.tui.identity_map"
    assert descriptor.session_strategy == {:tui_session, prefix: "ch_tui_"}

    assert {:ok, descriptor} = Channels.channel_descriptor("tui")
    assert descriptor.trust_class == :local
  end

  test "adapter routes terminal input through runtime and emits surface payload" do
    configure_tui!()
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:processed, event, ["[surface] hello tui"]}} =
             Adapter.submit(server, " hello tui ", external_event_id: "evt-tui-1")

    assert event.channel == "tui"
    assert event.provider == "terminal"
    assert event.status == "processed"

    assert_receive {:runtime_request, request}
    assert request.channel == "tui"
    assert request.text == "hello tui"
    assert request.user_id == "alice"
    assert String.starts_with?(request.session_id, "ch_tui_")
    assert request.channel_thread_ref.channel == "tui"
    assert request.channel_thread_ref.trust_class == "local"
    assert request.metadata.provider == "terminal"
    assert request.metadata.inbound_trust.permission == :channel_message_inbound

    assert_receive {:tui_output, "[surface] hello tui"}

    stored_event = Repo.get_by!(Event, channel: "tui", external_event_id: "evt-tui-1")
    assert stored_event.status == "processed"
    assert stored_event.user_id == "alice"
    assert stored_event.session_id == request.session_id
    assert stored_event.thread_id == request.thread_id
    assert is_binary(stored_event.input_signal_id)

    assert {:ok, %{messages: messages}} = Conversations.show_thread("alice", request.thread_id)
    assert Enum.at(messages, 1).content == "Clean TUI response: hello tui"
    refute Enum.any?(messages, &String.contains?(&1.content, "[surface]"))
  end

  test "non-interactive supervised child stays quiet without launcher opts" do
    configure_tui!()
    parent = self()

    assert {:ok, _server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    refute_receive {:tui_output, _line}, 50
  end

  test "adapter treats repeated terminal event ids as duplicates" do
    configure_tui!()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:ok, {:processed, _event, _rendered}} =
             Adapter.submit(server, "hello tui", external_event_id: "evt-tui-dupe")

    assert_receive {:runtime_request, _request}

    assert {:ok, :duplicate} =
             Adapter.submit(server, "hello again", external_event_id: "evt-tui-dupe")

    refute_received {:runtime_request, _request}
  end

  test "slash help renders canonical commands without runtime submission or channel event" do
    configure_tui!()
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok,
            {:slash,
             [
               "Available slash commands:\n" <>
                 "- /status\n" <>
                 "- /confirmations\n" <>
                 "- /events\n" <>
                 "- /channels\n" <>
                 "- /settings get\n" <>
                 "- /help"
             ]}} = Adapter.submit(server, "/help", external_event_id: "evt-tui-slash-help")

    refute_received {:runtime_request, _request}
    assert_receive {:tui_output, rendered}
    assert rendered =~ "/status"
    assert rendered =~ "/settings get"
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-help")
  end

  test "unknown slash command is inert and does not echo arguments" do
    configure_tui!()
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:slash, [rendered]}} =
             Adapter.submit(server, "/bogus token=secret",
               external_event_id: "evt-tui-slash-unknown"
             )

    assert rendered == "Unknown slash command. Type /help for available commands."
    refute rendered =~ "secret"
    refute_received {:runtime_request, _request}
    assert_receive {:tui_output, ^rendered}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-unknown")
  end

  test "operator slash data commands run internal read-only actions without runtime or channel events" do
    configure_tui!()
    assert {:ok, confirmation} = create_confirmation!("conf_tui_operator_console", "tui")
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:processed, _event, _rendered}} =
             Adapter.submit(server, "seed event", external_event_id: "evt-tui-inspection-seed")

    assert_receive {:runtime_request, %{text: "seed event"}}
    assert_receive {:tui_output, "[surface] seed event"}

    assert {:ok, {:slash, [status]}} =
             Adapter.submit(server, "/status", external_event_id: "evt-tui-slash-status")

    assert status =~ "Operator status:"
    assert status =~ "beam_os_pid:"
    assert status =~ "operator_id: alice"
    assert status =~ "Channels.Supervisor:"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-status")

    assert {:ok, {:slash, [channels]}} =
             Adapter.submit(server, "/channels", external_event_id: "evt-tui-slash-channels")

    assert channels =~ "Channels ("
    assert channels =~ "tui: provider=terminal enabled=true identities=1"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-channels")

    assert {:ok, {:slash, [confirmations]}} =
             Adapter.submit(server, "/confirmations",
               external_event_id: "evt-tui-slash-confirmations"
             )

    assert confirmations =~ confirmation["id"]
    assert confirmations =~ "status=pending"
    assert confirmations =~ "target=external_network_request"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-confirmations")

    assert {:ok, {:slash, [events]}} =
             Adapter.submit(server, "/events", external_event_id: "evt-tui-slash-events")

    assert events =~ "Recent channel events"
    assert events =~ "evt-tui-inspection-seed"
    refute events =~ "evt-tui-slash-events"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-events")

    assert {:ok, {:slash, [setting]}} =
             Adapter.submit(server, "/settings get channels.tui.identity_map",
               external_event_id: "evt-tui-slash-setting"
             )

    assert setting =~ "Setting channels.tui.identity_map:"
    assert setting =~ "alice"
    refute setting =~ "secret"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-setting")

    assert {:ok, {:slash, [invalid_setting]}} =
             Adapter.submit(server, "/settings get token=secret",
               external_event_id: "evt-tui-slash-setting-missing"
             )

    assert invalid_setting == "Invalid setting key."
    refute invalid_setting =~ "secret"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-setting-missing")
  end

  test "operator inspection actions are internal slash-only candidates" do
    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())

    for action_name <- [
          "operator_status",
          "operator_confirmations",
          "operator_events",
          "operator_channels",
          "operator_setting_get"
        ] do
      assert {:ok, module} = Registry.resolve(action_name)
      capability = module.capability()

      assert capability.permission == :read_only
      assert capability.exposure == :internal
      assert capability.confirmation == :not_required
      refute action_name in agent_action_names
    end
  end

  test "operator slash commands require mapped TUI identity before runner dispatch" do
    assert {:ok, _setting} = Settings.put("channels.tui.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("channels.tui.identity_map", [], %{audit?: false})
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:slash, [rendered]}} =
             Adapter.submit(server, "/status", external_event_id: "evt-tui-slash-unmapped")

    assert rendered ==
             "Slash command unavailable: terminal profile is not mapped to an Allbert user."

    refute_received {:runtime_request, _request}
    assert_receive {:tui_output, ^rendered}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-unmapped")
  end

  test "adapter generated terminal event ids are stable across launcher restarts" do
    configure_tui!()

    assert {:ok, first_server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:ok, {:processed, first_event, _rendered}} =
             Adapter.submit(first_server, "first generated id")

    assert_receive {:runtime_request, _request}
    GenServer.stop(first_server)

    assert {:ok, second_server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:ok, {:processed, second_event, _rendered}} =
             Adapter.submit(second_server, "second generated id")

    assert_receive {:runtime_request, _request}

    assert first_event.external_event_id =~
             ~r/^tui-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

    assert second_event.external_event_id =~
             ~r/^tui-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

    refute first_event.external_event_id == second_event.external_event_id
  end

  test "renderer emits typed commands and numbered approval options" do
    handoff = %{
      confirmation_id: "conf_tui_render",
      status: :pending,
      target_action: %{action: %{name: "write_note"}},
      allowed_actions: [:approve, :deny, :details]
    }

    assert {:ok, [rendered]} =
             Renderer.render_response(%{
               message: "model-only fallback",
               approval_handoff: handoff
             })

    assert rendered =~ "Approval: conf_tui_render status=pending target=write_note"
    assert rendered =~ "Type one exact command:"
    assert rendered =~ "ALLBERT:APPROVE:conf_tui_render"
    assert rendered =~ "Approval options:"
    assert rendered =~ "1. Approve - ALLBERT:APPROVE:conf_tui_render"
    assert rendered =~ "2. Deny - ALLBERT:DENY:conf_tui_render"
    refute rendered =~ "allbert:v1:"
    refute rendered =~ "http"
  end

  test "renderer status line does not duplicate the input prompt" do
    prompt_text = Renderer.prompt("default") |> Owl.Data.untag() |> IO.iodata_to_binary()
    status_text = Renderer.status("default", :ready) |> Owl.Data.untag() |> IO.iodata_to_binary()

    assert prompt_text == "allbert:default> "
    assert status_text == "tui(default) ready"
    refute status_text =~ "allbert:default>"
  end

  test "typed confirmation commands resolve without runtime submission" do
    configure_tui!()
    assert {:ok, confirmation} = create_confirmation!("conf_tui_typed", "tui")
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               emit_banner?: true,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert_receive {:tui_output, _banner}
    assert_receive {:tui_output, _banner}

    assert {:ok, {:processed, event, [rendered]}} =
             Adapter.submit(server, "ALLBERT:DENY:#{confirmation["id"]}",
               external_event_id: "evt-tui-callback"
             )

    refute_received {:runtime_request, %{text: "ALLBERT:DENY:" <> _rest}}
    assert_receive {:tui_output, output}

    assert event.direction == "callback"
    assert event.status == "processed"
    assert event.user_id == "alice"
    assert rendered =~ "denied"
    assert output =~ "denied"

    assert {:ok, resolved} = Confirmations.read(confirmation["id"])
    assert resolved["status"] == "denied"
    assert resolved["operator_resolution"]["resolver_actor"] == "alice"
    assert resolved["operator_resolution"]["resolver_channel"] == "tui"
    assert resolved["operator_resolution"]["resolver_metadata"]["command"] =~ "DENY"
  end

  test "typed confirmation commands cannot resolve other-channel confirmations" do
    configure_tui!()
    assert {:ok, confirmation} = create_confirmation!("conf_tui_wrong_channel", "slack")

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:ok, :rejected} =
             Adapter.submit(server, "ALLBERT:DENY:#{confirmation["id"]}",
               external_event_id: "evt-tui-wrong-channel"
             )

    refute_received {:runtime_request, _request}

    event = Repo.get_by!(Event, channel: "tui", external_event_id: "evt-tui-wrong-channel")
    assert event.direction == "callback"
    assert event.status == "rejected"
    assert event.reason == ":wrong_channel"

    assert {:ok, pending} = Confirmations.read(confirmation["id"])
    assert pending["status"] == "pending"
  end

  test "adapter rejects unmapped terminal identity without invoking runtime" do
    assert {:ok, _setting} = Settings.put("channels.tui.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("channels.tui.identity_map", [], %{audit?: false})

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:ok, :rejected} =
             Adapter.submit(server, "hello tui", external_event_id: "evt-tui-reject")

    refute_received {:runtime_request, _request}

    event = Repo.get_by!(Event, channel: "tui", external_event_id: "evt-tui-reject")
    assert event.status == "rejected"
    assert event.reason == ":not_mapped"
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

  defp create_confirmation!(id, channel) do
    Confirmations.create(%{
      id: id,
      origin: %{actor: "alice", channel: channel, surface: "tui-test"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    })
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end
end
