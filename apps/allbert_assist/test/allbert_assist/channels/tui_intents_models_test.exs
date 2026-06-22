defmodule AllbertAssist.Channels.TUIIntentsModelsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.TUI.Adapter
  alias AllbertAssist.Channels.TUI.SlashCommands
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
        "allbert-tui-intents-models-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})

        {:ok,
         %{
           model_payload: "M12 model response: #{request.text}",
           surface_payload: "[surface] #{request.text}",
           status: :completed
         }}
      end
    )

    PluginRegistry.clear()
    assert {:ok, "allbert.tui"} = PluginRegistry.register_module(TUIPlugin)
    Fragments.clear_cache()
    configure_tui!()

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

  test "/intents and /models are slash-only read views over registered actions" do
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert SlashCommands.requires_identity?("/intents")
    assert SlashCommands.requires_identity?("/models")

    assert {:ok, {:slash, [intents]}} =
             Adapter.submit(server, "/intents", external_event_id: "evt-v056-slash-intents")

    assert intents =~ "coverage: routable="
    assert intents =~ "learned_review="
    refute_received {:runtime_request, _request}
    assert_receive {:tui_output, ^intents}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-v056-slash-intents")

    assert {:ok, {:slash, [models]}} =
             Adapter.submit(server, "/models", external_event_id: "evt-v056-slash-models")

    assert models =~ "model doctor ok="
    assert models =~ "intent_embedding"
    assert models =~ "intent_escalation"
    assert models =~ "gemma4:26b"
    refute models =~ "secret://"
    refute models =~ "api_key"
    refute models =~ "http://"
    refute_received {:runtime_request, _request}
    assert_receive {:tui_output, ^models}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-v056-slash-models")
  end

  test "v0.56 TUI read slash commands are allowlisted but not routable intent candidates" do
    commands = SlashCommands.canonical_commands()
    assert "/intents" in commands
    assert "/models" in commands

    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())

    for action_name <- ["intent_coverage", "model_doctor"] do
      assert {:ok, module} = Registry.resolve(action_name)
      capability = module.capability()

      assert capability.permission == :read_only
      assert capability.exposure == :internal
      assert capability.confirmation == :not_required
      refute action_name in agent_action_names
    end
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

    assert {:ok, _setting} =
             Settings.put("providers.local_ollama.base_url", "http://127.0.0.1:1/v1", %{
               audit?: false
             })
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_plugins(entries) do
    PluginRegistry.clear()
    Enum.each(entries, &PluginRegistry.register_entry/1)
  end
end
