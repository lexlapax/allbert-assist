defmodule AllbertAssist.Security.V0551OperatorConsoleEvalTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :security_eval_serial
  @moduletag :app_env_serial
  @moduletag :global_process_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.TUI.Adapter, as: TUIAdapter
  alias AllbertAssist.Channels.TUI.SlashCommands
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace
  alias Mix.Tasks.Allbert.Channels, as: ChannelsTask

  @operator_action_names [
    "operator_status",
    "operator_confirmations",
    "operator_events",
    "operator_channels",
    "operator_setting_get"
  ]

  @eval_groups [
    slash_readonly: [
      "tui-slash-readonly-001",
      "tui-slash-parse-001"
    ],
    source_status: [
      "tui-slash-source-of-truth-001",
      "tui-channel-status-redaction-001"
    ],
    warm_session: [
      "tui-console-warm-session-001"
    ],
    settings: [
      "tui-settings-get-redaction-001"
    ],
    candidates: [
      "tui-inspection-not-agent-candidate-001"
    ]
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()

    parent = self()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v0551-operator-console-eval-#{System.unique_integer([:positive])}"
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
           model_payload: "v0.55.1 model: #{request.text}",
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
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
      Mix.Task.reenable("allbert.channels")
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "v0.55.1 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v0551)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.surface == :channel_pack))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "slash inspection commands are read-only runner actions and malformed slash is inert" do
    assert_eval_group!(:slash_readonly)
    assert {:ok, confirmation} = create_confirmation!("conf_v0551_console", "tui")
    assert {:ok, server} = start_tui_adapter()

    slash_cases = [
      {"/status", "evt-v0551-slash-status", "Operator status:"},
      {"/channels", "evt-v0551-slash-channels", "Channels ("},
      {"/events", "evt-v0551-slash-events", "Recent channel events"},
      {"/confirmations", "evt-v0551-slash-confirmations", confirmation["id"]},
      {"/settings get channels.tui.identity_map", "evt-v0551-slash-settings",
       "Setting channels.tui.identity_map:"}
    ]

    for {command, event_id, expected_text} <- slash_cases do
      assert {:ok, {:slash, [rendered]}} =
               TUIAdapter.submit(server, command, external_event_id: event_id)

      assert rendered =~ expected_text
      refute_received {:runtime_request, _request}
      refute Repo.get_by(Event, channel: "tui", external_event_id: event_id)
    end

    assert {:ok, {:slash, [unknown]}} =
             TUIAdapter.submit(server, "/unknown token=secret",
               external_event_id: "evt-v0551-slash-unknown"
             )

    assert unknown == "Unknown slash command. Type /help for available commands."
    refute unknown =~ "secret"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-v0551-slash-unknown")

    assert {:ok, {:slash, [invalid_setting]}} =
             TUIAdapter.submit(server, "/settings get token=secret",
               external_event_id: "evt-v0551-slash-invalid-setting"
             )

    assert invalid_setting == "Invalid setting key."
    refute invalid_setting =~ "secret"
    refute_received {:runtime_request, _request}

    refute Repo.get_by(Event,
             channel: "tui",
             external_event_id: "evt-v0551-slash-invalid-setting"
           )
  end

  test "/channels and mix allbert.channels status share one redacted report" do
    assert_eval_group!(:source_status)
    assert {:ok, server} = start_tui_adapter()

    assert {:ok, {:slash, [slash_channels]}} =
             TUIAdapter.submit(server, "/channels",
               external_event_id: "evt-v0551-slash-channels-source"
             )

    Mix.Task.reenable("allbert.channels")

    status_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["status"])
      end)

    assert normalize_output(status_output) == normalize_output(slash_channels)
    assert slash_channels =~ "Channels.Supervisor:"
    assert slash_channels =~ "tui: provider=terminal"
    assert slash_channels =~ "telegram: provider=telegram_bot_api"
    assert slash_channels =~ "credentials="
    assert_secret_free!(slash_channels)
    assert_secret_free!(status_output)
  end

  test "warm status identity remains stable across slash and normal turns" do
    assert_eval_group!(:warm_session)
    assert {:ok, server} = start_tui_adapter()

    assert {:ok, {:slash, [before_status]}} =
             TUIAdapter.submit(server, "/status", external_event_id: "evt-v0551-status-before")

    assert {:ok, {:processed, event, ["[surface] warm console check"]}} =
             TUIAdapter.submit(server, "warm console check",
               external_event_id: "evt-v0551-warm-turn"
             )

    assert_receive {:runtime_request, %{text: "warm console check", user_id: "alice"}}
    assert event.status == "processed"

    assert {:ok, {:slash, [after_status]}} =
             TUIAdapter.submit(server, "/status", external_event_id: "evt-v0551-status-after")

    assert line_value(before_status, "beam_os_pid") == line_value(after_status, "beam_os_pid")
    assert line_value(before_status, "node") == line_value(after_status, "node")
    assert uptime(after_status) >= uptime(before_status)

    assert {:ok, {:slash, [events]}} =
             TUIAdapter.submit(server, "/events", external_event_id: "evt-v0551-events-after")

    assert events =~ "evt-v0551-warm-turn"
    refute events =~ "evt-v0551-status-before"
    refute events =~ "evt-v0551-status-after"
  end

  test "/settings get uses the operator setting action and redacts secret-bearing values" do
    assert_eval_group!(:settings)

    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/discord/bot_token", "xoxb-v0551-secret", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put(
               "channels.discord.bot_token_ref",
               "secret://channels/discord/bot_token",
               %{audit?: false}
             )

    assert SlashCommands.requires_identity?("/settings get channels.discord.bot_token_ref")

    assert {:ok, response} =
             SlashCommands.dispatch(
               "/settings get channels.discord.bot_token_ref",
               operator_context()
             )

    rendered = response.surface_payload

    assert response.runner_metadata.action_name == "operator_setting_get"
    assert rendered =~ "Setting channels.discord.bot_token_ref:"
    assert rendered =~ "[REDACTED]"
    refute rendered =~ "xoxb-v0551-secret"
    refute rendered =~ "secret://channels/discord/bot_token"
    refute inspect(response.setting) =~ "xoxb-v0551-secret"
    refute inspect(response.setting) =~ "secret://channels/discord/bot_token"
  end

  test "operator inspection actions are not model-routable candidates" do
    assert_eval_group!(:candidates)

    agent_names = Registry.agent_modules() |> Enum.map(& &1.name()) |> MapSet.new()
    agent_capability_names = Registry.agent_capabilities() |> Enum.map(& &1.name) |> MapSet.new()
    descriptor_names = DescriptorResolver.resolve() |> Enum.map(& &1.action_name) |> MapSet.new()

    for action_name <- @operator_action_names do
      assert {:ok, module} = Registry.resolve(action_name)
      capability = module.capability()

      assert capability.permission == :read_only
      assert capability.exposure == :internal
      assert capability.confirmation == :not_required
      refute MapSet.member?(agent_names, action_name)
      refute MapSet.member?(agent_capability_names, action_name)
      refute MapSet.member?(descriptor_names, action_name)
    end
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

  defp start_tui_adapter do
    parent = self()

    TUIAdapter.start_link(
      name: nil,
      auto_input?: false,
      enabled?: true,
      live_screen?: false,
      output_fun: fn line -> send(parent, {:tui_output, line}) end
    )
  end

  defp create_confirmation!(id, channel) do
    Confirmations.create(%{
      id: id,
      origin: %{actor: "alice", channel: channel, surface: "v0551-eval"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    })
  end

  defp operator_context do
    %{
      actor: "alice",
      user_id: "alice",
      operator_id: "alice",
      channel: "tui",
      provider: "terminal",
      surface: "tui_slash_command",
      external_user_id: "default",
      receiver_account_ref: "tui:default",
      request: %{
        channel: "tui",
        provider: "terminal",
        user_id: "alice",
        operator_id: "alice",
        surface: "tui_slash_command",
        external_user_id: "default",
        receiver_account_ref: "tui:default"
      }
    }
  end

  defp assert_eval_group!(group) do
    ids = Keyword.fetch!(@eval_groups, group)
    milestone_rows = EvalInventory.rows_for_milestone(:v0551)
    rows = Enum.map(ids, &find_eval_row!(milestone_rows, &1))

    assert Enum.map(rows, & &1.id) == ids
    assert Enum.all?(rows, &(&1.milestone == :v0551))
    assert Enum.all?(rows, &(&1.surface == :channel_pack))
  end

  defp find_eval_row!(rows, id) do
    Enum.find(rows, &(&1.id == id)) || flunk("missing v0.55.1 eval row #{id}")
  end

  defp normalize_output(output) do
    output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp assert_secret_free!(output) do
    refute output =~ "secret://"
    refute output =~ "xoxb-v0551-secret"
    refute output =~ "bot_token"
    refute output =~ "app_token"
  end

  defp line_value(rendered, label) do
    case Regex.run(~r/- #{Regex.escape(label)}: ([^\n]+)/, rendered) do
      [_, value] -> String.trim(value)
      _match -> flunk("missing #{label} in #{rendered}")
    end
  end

  defp uptime(rendered) do
    rendered
    |> line_value("uptime_ms")
    |> String.to_integer()
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
