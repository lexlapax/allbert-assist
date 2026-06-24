defmodule AllbertAssist.Security.V057CodingEvalTest do
  @moduledoc """
  v0.57 Pi-mode coding surface release evals.
  """
  use AllbertAssist.DataCase, async: false
  @moduletag :security_eval_serial
  @moduletag :app_env_serial
  @moduletag :global_process_serial
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.TUI.Adapter, as: TUIAdapter
  alias AllbertAssist.Channels.TUI.SlashCommands
  alias AllbertAssist.Coding.CommandGrants
  alias AllbertAssist.Coding.Prompt
  alias AllbertAssist.Coding.Session, as: CodingSession
  alias AllbertAssist.Coding.StreamEvent
  alias AllbertAssist.Coding.StreamPipeline
  alias AllbertAssist.Coding.StreamRenderer
  alias AllbertAssist.Coding.TurnSupervisor
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin
  alias AllbertAssist.PublicProtocol.ExposureFilter
  alias AllbertAssist.Repo
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Runtime
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Trace

  @tool_names ~w(read grep glob write edit bash)
  @slash_names ~w(/pi /mode /model /clear /init /diff /compact)

  @eval_groups [
    action_boundary: ~w(
      pi-mode-tools-route-through-runner-001
      pi-mode-tools-denied-out-of-session-001
      pi-mode-permission-vocabulary-001
      pi-mode-read-search-policy-bounded-001
      pi-mode-bash-policy-bounded-001
      pi-mode-bash-raw-shell-tier-only-001
      pi-mode-write-edit-cwd-jail-001
      pi-mode-file-effects-tier-gated-001
      pi-mode-deterministic-acceptance-001
      pi-mode-no-authority-001
    ),
    trust_and_approval: ~w(
      local-coding-tier-trusted-only-001
      local-coding-tier-not-default-001
      local-coding-tier-rejects-channel-origin-001
      pi-mode-approval-mode-grants-no-authority-001
      pi-mode-cheap-gate-preserves-decision-001
      pi-mode-command-grant-scoped-revocable-auditable-001
      pi-mode-no-bash-subagent-001
    ),
    prompt_context_model: ~w(
      split-result-no-ui-leak-001
      pi-mode-prompt-token-budget-001
      pi-mode-context-discipline-chunked-001
      pi-mode-default-tool-surface-001
      pi-mode-model-switch-preserves-authority-001
    ),
    streaming_cancel: ~w(
      pi-mode-turn-supervised-cancellable-001
      pi-mode-stream-event-contract-001
      pi-mode-assistant-text-streams-001
      pi-mode-interrupt-clean-cancel-001
    ),
    slash_session: ~w(
      pi-mode-slash-effects-action-backed-001
      pi-mode-coding-slash-non-routable-001
    )
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()

    root = Path.join(System.tmp_dir!(), "allbert-v057-coding-eval-#{unique()}")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")

    File.mkdir_p!(home)
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join(workspace, ".git"))
    File.write!(Path.join(workspace, "sample.txt"), "alpha\nneedle\nomega\n")
    File.write!(Path.join(workspace, "lib/code.ex"), "alpha\nneedle\nomega\n")
    File.write!(Path.join(workspace, "existing.txt"), "existing\n")
    File.write!(Path.join(outside, "secret.txt"), "outside\n")
    File.ln_s!(outside, Path.join(workspace, "outlink"))

    Enum.each(@env_vars, &System.delete_env/1)
    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    assert {:ok, "allbert.tui"} = PluginRegistry.register_module(TUIPlugin)
    Fragments.clear_cache()

    configure_settings!(workspace)

    on_exit(fn ->
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Runtime, original_runtime_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(Trace, original_trace_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    {:ok, home: home, workspace: workspace}
  end

  test "v0.57 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v057)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.surface == :pi_mode_coding))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "tool surface routes through registry and permission vocabulary is exact", %{
    workspace: workspace
  } do
    assert_eval_group!(:action_boundary)

    permissions = %{
      "read" => :coding_file_read,
      "grep" => :coding_file_read,
      "glob" => :coding_file_read,
      "write" => :coding_file_write,
      "edit" => :coding_file_write,
      "bash" => :coding_shell_execute
    }

    agent_names = Registry.agent_modules() |> Enum.map(& &1.name()) |> MapSet.new()

    for {name, permission} <- permissions do
      assert {:ok, capability} = Registry.capability(name)
      assert capability.permission == permission
      assert capability.exposure == :internal
      refute MapSet.member?(agent_names, name)
    end

    assert {:error, {:non_exposable_tools, rejected}} =
             ExposureFilter.filter_tools(@tool_names)

    assert Enum.map(rejected, & &1.name) == @tool_names

    assert Enum.all?([:coding_file_read, :coding_file_write, :coding_shell_execute], fn atom ->
             atom in PermissionGate.permission_classes()
           end)

    refute :coding_session_write in PermissionGate.permission_classes()

    for {key, value} <- [
          {"permissions.coding_file_read", "allowed"},
          {"permissions.coding_file_write", "needs_confirmation"},
          {"permissions.coding_shell_execute", "needs_confirmation"},
          {"coding.prompt.token_budget", 1_000},
          {"coding.prompt.tokenizer", "simple_words"},
          {"coding.model_profile", "coding_local"}
        ] do
      assert key in Schema.safe_write_keys()
      assert :ok = Schema.validate_key_value(key, value)
    end

    assert {:ok, response} =
             Runner.run("read", %{path: "sample.txt", limit: 1}, trusted_context(workspace))

    assert response.status == :completed
    assert response.actions |> hd() |> Map.fetch!(:permission) == :coding_file_read
  end

  test "coding tools deny out-of-session direct invocation before filesystem access", %{
    workspace: workspace
  } do
    assert_eval_group!(:action_boundary)

    assert {:ok, response} = Runner.run("read", %{path: "sample.txt", limit: 1}, %{})
    assert response.status == :denied
    assert response.actions |> hd() |> Map.fetch!(:denial_reason) == :coding_session_required

    channel_context =
      workspace
      |> trusted_context()
      |> put_in([:coding, :pi_mode_enabled], false)

    assert {:ok, channel_response} =
             Runner.run("grep", %{pattern: "needle", max_results: 1}, channel_context)

    assert channel_response.status == :denied

    assert channel_response.actions |> hd() |> Map.fetch!(:denial_reason) ==
             :coding_session_required
  end

  test "read search prompt and context discipline stay bounded", %{workspace: workspace} do
    assert_eval_group!(:prompt_context_model)

    assert {:ok, read} =
             Runner.run(
               "read",
               %{path: "sample.txt", offset: 0, limit: 1},
               trusted_context(workspace)
             )

    assert read.status == :completed
    assert read.file.returned_lines == 1
    assert read.file.limit == 1

    assert {:ok, grep} =
             Runner.run(
               "grep",
               %{pattern: "needle", path: ".", max_results: 1},
               trusted_context(workspace)
             )

    assert grep.status == :completed
    assert grep.grep.match_count == 1

    assert {:ok, glob} =
             Runner.run(
               "glob",
               %{pattern: "**/*.txt", max_results: 2},
               trusted_context(workspace)
             )

    assert glob.status == :completed
    assert glob.glob.match_count <= 2

    bundle = Prompt.surface_bundle()
    assert bundle.tokenizer == "simple_words"
    assert bundle.within_budget?
    assert bundle.token_count < bundle.token_budget
    assert Enum.map(bundle.tools, & &1.name) == @tool_names

    assert {:ok, session} = CodingSession.start(workspace, trusted_context(workspace))
    assert Enum.map(session.req_llm_context.tools, & &1.name) == @tool_names
  end

  test "file effects are cwd-jailed gated and split surface diffs from model payload", %{
    workspace: workspace
  } do
    assert_eval_group!(:action_boundary)
    default_context = trusted_context(workspace)

    assert {:ok, write} =
             Runner.run("write", %{path: "new.txt", content: "hello\n"}, default_context)

    assert write.status == :needs_confirmation
    assert write.permission_decision.decision == :needs_confirmation
    assert write.permission_decision.requires_confirmation
    refute File.exists?(Path.join(workspace, "new.txt"))
    assert write.model_payload =~ "needs confirmation"
    refute write.model_payload =~ "--- /dev/null"
    assert write.surface_payload =~ "--- /dev/null"

    assert {:ok, edit} =
             Runner.run(
               "edit",
               %{path: "lib/code.ex", old_text: "needle\n", new_text: "needle edited\n"},
               default_context
             )

    assert edit.status == :needs_confirmation
    assert File.read!(Path.join(workspace, "lib/code.ex")) == "alpha\nneedle\nomega\n"
    assert edit.model_payload =~ "replacements=1"
    refute edit.model_payload =~ "exact replacements=1"
    assert edit.surface_payload =~ "exact replacements=1"

    for {action, params} <- [
          {"write", %{path: "../outside/new.txt", content: "x\n"}},
          {"write", %{path: "outlink/new.txt", content: "x\n"}},
          {"write", %{path: "existing.txt", content: "x\n"}},
          {"edit", %{path: "../outside/secret.txt", old_text: "outside", new_text: "inside"}},
          {"edit", %{path: "outlink/secret.txt", old_text: "outside", new_text: "inside"}}
        ] do
      assert {:ok, denied} = Runner.run(action, params, default_context)
      assert denied.status == :denied
    end

    accept_context = approval_context(workspace, "accept-edits")

    assert {:ok, accepted} =
             Runner.run("write", %{path: "accepted.txt", content: "accepted\n"}, accept_context)

    assert accepted.status == :completed
    assert accepted.permission_decision.decision == :needs_confirmation
    refute accepted.permission_decision.requires_confirmation
    assert File.read!(Path.join(workspace, "accepted.txt")) == "accepted\n"

    channel_context = Map.put(accept_context, :channel_originated?, true)

    assert {:ok, channel_write} =
             Runner.run("write", %{path: "channel.txt", content: "blocked\n"}, channel_context)

    assert channel_write.status == :denied

    assert channel_write.actions |> hd() |> Map.fetch!(:denial_reason) ==
             :local_coding_operator_required

    refute File.exists?(Path.join(workspace, "channel.txt"))
  end

  test "bash is policy bounded raw shell is tier-only and sub-agent spawn is refused", %{
    workspace: workspace
  } do
    assert_eval_group!(:action_boundary)
    context = trusted_context(workspace)

    assert {:ok, argv} =
             Runner.run("bash", %{executable: "printf", args: ["hi"], cwd: "."}, context)

    assert argv.status == :needs_confirmation
    assert argv.permission_decision.decision == :needs_confirmation
    assert argv.permission_decision.requires_confirmation

    assert {:ok, outside_cwd} =
             Runner.run(
               "bash",
               %{executable: "printf", args: ["hi"], cwd: "../outside"},
               context
             )

    assert outside_cwd.status == :denied

    assert {:ok, too_long} =
             Runner.run(
               "bash",
               %{executable: "printf", args: ["hi"], cwd: ".", timeout_ms: 99_999},
               context
             )

    assert too_long.status == :denied

    assert {:ok, raw_disabled} =
             Runner.run("bash", %{command: "printf hi", cwd: "."}, context)

    assert raw_disabled.status == :denied
    assert raw_disabled.error == :raw_shell_disabled

    assert {:ok, _setting} = Settings.put("coding.bash.allow_raw_shell", true, %{audit?: false})

    channel_context = Map.put(context, :channel_originated?, true)

    assert {:ok, raw_channel} =
             Runner.run("bash", %{command: "printf hi", cwd: "."}, channel_context)

    assert raw_channel.status == :denied
    assert raw_channel.error == :local_coding_operator_required

    assert {:ok, subagent} =
             Runner.run("bash", %{command: "codex run tests", cwd: "."}, context)

    assert subagent.status == :denied
    assert subagent.error == :bash_spawned_subagent_not_allowed
  end

  test "trust tier approval modes and command grants change cost but not authority", %{
    workspace: workspace
  } do
    assert_eval_group!(:trust_and_approval)
    context = trusted_context(workspace)

    assert PermissionGate.coding_tier(context) == :local_coding_operator

    assert PermissionGate.coding_tier(%{context | actor: "other"}) == :none

    assert PermissionGate.coding_tier(%{context | channel: %{name: :slack, trust: :local}}) ==
             :none

    assert PermissionGate.coding_tier(%{context | session: %{main?: false}}) == :none
    assert PermissionGate.coding_tier(Map.put(context, :channel_originated?, true)) == :none
    assert PermissionGate.coding_tier(Map.put(context, :scheduled?, true)) == :none
    assert PermissionGate.coding_tier(Map.put(context, :generated_code_session?, true)) == :none

    setting_controlled_context = update_in(context, [:coding], &Map.delete(&1, :pi_mode_enabled))

    assert {:ok, _setting} = Settings.put("coding.pi_mode.enabled", false, %{audit?: false})
    assert PermissionGate.coding_tier(setting_controlled_context) == :none
    assert {:ok, _setting} = Settings.put("coding.pi_mode.enabled", true, %{audit?: false})

    default_write = PermissionGate.authorize(:coding_file_write, context)
    assert default_write.decision == :needs_confirmation
    assert default_write.requires_confirmation

    accept_write =
      PermissionGate.authorize(:coding_file_write, approval_context(workspace, "accept-edits"))

    assert accept_write.decision == :needs_confirmation
    refute accept_write.requires_confirmation
    assert accept_write.policy.effective == :needs_confirmation
    assert accept_write.trace.confirmation_cost == :suppressed

    plan_context = approval_context(workspace, "plan")
    assert PermissionGate.authorize(:coding_file_read, plan_context).decision == :allowed
    assert PermissionGate.authorize(:coding_file_write, plan_context).decision == :denied
    assert PermissionGate.authorize(:coding_shell_execute, plan_context).decision == :denied

    tier_shell =
      PermissionGate.authorize(:coding_shell_execute, approval_context(workspace, "tier"))

    assert tier_shell.decision == :needs_confirmation
    refute tier_shell.requires_confirmation
    assert tier_shell.policy.effective == :needs_confirmation

    params = %{mode: :argv, executable: "printf", args: ["hello"], cwd: workspace}

    assert {:ok, grant} =
             CommandGrants.remember(params,
               context: context,
               permission: :coding_shell_execute,
               audit?: false
             )

    assert get_in(grant, ["scope", "kind"]) == "canonical_command"
    refute inspect(grant) =~ "hello"

    command_context = put_in(context, [:coding, :command_params], params)
    grant_decision = PermissionGate.authorize(:coding_shell_execute, command_context)
    assert grant_decision.decision == :needs_confirmation
    refute grant_decision.requires_confirmation

    assert {:error, :no_matching_command_grant} =
             CommandGrants.find_applicable(%{params | args: ["different"]},
               context: context,
               permission: :coding_shell_execute
             )

    assert {:ok, _revoked} = Grants.revoke(grant["id"], %{audit?: false})
  end

  test "stream events render assistant deltas and Esc cancellation leaves partial evidence", %{
    home: home
  } do
    assert_eval_group!(:streaming_cancel)

    assert StreamEvent.types() == [
             :assistant_token_delta,
             :tool_call_argument_delta,
             :tool_call_argument_complete,
             :tool_result_delta,
             :turn_cancelled,
             :turn_complete
           ]

    assert {:ok, token} =
             StreamEvent.new(:assistant_token_delta, %{turn_id: "turn-v057", text: "Working"})

    assert {:ok, tool} =
             StreamEvent.new(:tool_call_argument_delta, %{
               turn_id: "turn-v057",
               tool_call_id: "call-1",
               tool_name: "edit",
               arguments_delta: %{"path" => "lib/code.ex"}
             })

    assert {:ok, complete} =
             StreamPipeline.turn_complete_event(
               %{
                 model_payload: "model-clean",
                 surface_payload: "surface diff",
                 status: :completed
               },
               turn_id: "turn-v057"
             )

    assert {:ok, rendered_state} =
             "turn-v057"
             |> StreamRenderer.new()
             |> StreamRenderer.apply_events([token, tool, complete])

    assert StreamRenderer.render(rendered_state) == "surface diff"
    refute StreamRenderer.render(rendered_state) =~ "model-clean"

    parent = self()
    turn_id = "v057-cancel-#{unique()}"
    Application.put_env(:allbert_assist, Trace, enabled: true)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runner_started, request})

        :ok =
          TurnSupervisor.register_stream_cancel(request.coding_turn_id, fn ->
            send(parent, {:stream_cancelled, request.coding_turn_id})
          end)

        receive do
          :finish_turn -> {:ok, %{message: "should not complete", status: :completed}}
        end
      end
    )

    task =
      Task.async(fn ->
        Runtime.submit_user_input(%{
          text: "cancel this v057 coding turn",
          channel: :test,
          user_id: "v057-cancel",
          new_thread: true,
          coding_turn?: true,
          coding_turn_id: turn_id
        })
      end)

    assert_receive {:runner_started, %{coding_turn?: true, coding_turn_id: ^turn_id}}, 5_000
    assert {:ok, %{stream_cancel: :ok, shutdown: :ok}} = TurnSupervisor.cancel(turn_id, :escape)
    assert_receive {:stream_cancelled, ^turn_id}, 1_000

    assert {:ok, response} = Task.await(task, 5_000)
    assert response.status == :cancelled
    assert [%{type: :turn_cancelled, turn_id: ^turn_id}] = response.stream_events
    assert response.trace_id =~ Path.join(home, "memory/traces")
    assert File.exists?(response.trace_id)
    assert {:error, :not_found} = TurnSupervisor.lookup(turn_id)
  end

  test "slash session commands are non-routable action-backed where effectful", %{
    workspace: workspace
  } do
    assert_eval_group!(:slash_session)
    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runtime_request, request})
        {:ok, %{model_payload: request.text, surface_payload: request.text, status: :completed}}
      end
    )

    assert {:ok, server} =
             TUIAdapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:slash, [help]}} = TUIAdapter.submit(server, "/help")
    assert help =~ "/pi"
    assert help =~ "/mode"
    assert help =~ "/compact"

    assert {:ok, {:slash, [entered]}} =
             TUIAdapter.submit(server, "/pi #{workspace}", external_event_id: "evt-v057-pi")

    assert entered =~ "Pi-mode entered"
    refute_event("evt-v057-pi")

    assert {:ok, {:slash, [diff]}} =
             TUIAdapter.submit(server, "/diff sample.txt", external_event_id: "evt-v057-diff")

    assert diff =~ "Read-only diff context:"
    assert diff =~ "needle"
    refute_event("evt-v057-diff")

    assert {:ok, {:at_file, [file]}} =
             TUIAdapter.submit(server, "@sample.txt", external_event_id: "evt-v057-at-file")

    assert file =~ "sample.txt"
    refute_event("evt-v057-at-file")

    assert {:ok, {:slash, [mode]}} = TUIAdapter.submit(server, "/mode plan")
    assert mode == "Pi-mode approval mode switched to plan."

    assert {:ok, {:slash, [denied_init]}} = TUIAdapter.submit(server, "/init denied.md")
    assert denied_init =~ "permission gate returned denied"

    assert {:ok, {:slash, [mode_default]}} = TUIAdapter.submit(server, "/mode default")
    assert mode_default == "Pi-mode approval mode switched to default."

    assert {:ok, {:slash, [init]}} = TUIAdapter.submit(server, "/init pi.md")
    assert init =~ "Approval:"
    assert init =~ "target=write"

    assert {:ok, {:slash, [model]}} = TUIAdapter.submit(server, "/model coding_local")
    assert model == "Pi-mode model switched to coding_local."

    for slash <- @slash_names do
      refute slash in Enum.map(Registry.agent_modules(), & &1.name())
      assert {:error, {:unknown_action, ^slash}} = Registry.capability(slash)
      assert slash in SlashCommands.canonical_commands()
    end

    refute_received {:runtime_request, _request}

    assert {:ok, session} = CodingSession.start(workspace, trusted_context(workspace))

    response = %ReqLLM.Response{
      id: "resp-v057",
      model: "fixture",
      context: nil,
      message: ReqLLM.Context.assistant("hello")
    }

    assert {:ok, merged, _response} = CodingSession.merge_response(session, response)
    assert {:ok, switched} = CodingSession.switch_model(merged, "coding_local")
    assert length(switched.req_llm_context.messages) == 2
    assert switched.model_profile == "coding_local"
  end

  defp assert_eval_group!(group) do
    expected = MapSet.new(Keyword.fetch!(@eval_groups, group))
    rows = EvalInventory.rows_for_milestone(:v057)
    row_ids = rows |> Enum.map(& &1.id) |> MapSet.new()

    assert MapSet.subset?(expected, row_ids)
  end

  defp configure_settings!(workspace) do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "execution" => %{
                 "local" => %{
                   "enabled" => true,
                   "allowed_roots" => [workspace],
                   "allowed_commands" => ["pwd", "printf"],
                   "env_allowlist" => [],
                   "max_timeout_ms" => 1_000,
                   "max_output_bytes" => 2_000
                 }
               }
             })

    assert {:ok, _setting} = Settings.put("channels.tui.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.tui.identity_map",
               [%{"external_user_id" => "default", "user_id" => "local", "enabled" => true}],
               %{audit?: false}
             )

    assert {:ok, _setting} = Settings.put("coding.pi_mode.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("coding.trusted_operator_id", "local", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("coding.default_approval_mode", "default", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("coding.workspace.cwd_jail", workspace, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("coding.model_profile", "coding_local", %{audit?: false})
  end

  defp trusted_context(workspace) do
    %{
      actor: "local",
      operator_id: "local",
      user_id: "local",
      channel: %{name: :tui, trust: :local},
      surface: :tui,
      cwd_jail: workspace,
      coding: %{cwd_jail: workspace, pi_mode_enabled: true, trusted_operator_id: "local"},
      session: %{main?: true}
    }
  end

  defp approval_context(workspace, approval_mode) do
    put_in(trusted_context(workspace), [:coding, :approval_mode], approval_mode)
  end

  defp refute_event(external_event_id) do
    refute Repo.get_by(Event, channel: "tui", external_event_id: external_event_id)
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp unique, do: System.unique_integer([:positive])
end
