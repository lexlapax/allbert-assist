defmodule AllbertAssist.Coding.M8SessionSlashTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.TUI.Adapter
  alias AllbertAssist.Channels.TUI.SlashCommands
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Coding.PathPolicy
  alias AllbertAssist.Coding.Prompt
  alias AllbertAssist.Coding.Session, as: CodingSession
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Schema
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
        "allbert-coding-m8-#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    other_repo = Path.join(root, "other-repo")
    link = Path.join(root, "repo-link")

    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.mkdir_p!(other_repo)
    File.write!(Path.join(repo, "sample.txt"), "from pinned repo\n")
    File.write!(Path.join(other_repo, "sample.txt"), "from changed setting\n")
    File.ln_s!(repo, link)

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
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
           model_payload: "runtime #{request.text}",
           surface_payload: "runtime #{request.text}",
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

    {:ok, root: root, repo: repo, other_repo: other_repo, link: link}
  end

  test "prompt and six tool definitions fit the configured M8 budget" do
    for {key, value} <- [
          {"coding.prompt.token_budget", 1_000},
          {"coding.prompt.tokenizer", "simple_words"},
          {"coding.model_profile", "pi_coding_local"}
        ] do
      assert key in Schema.safe_write_keys()
      assert %{writable?: true, sensitive?: false} = Schema.schema()[key]
      assert :ok = Schema.validate_key_value(key, value)
    end

    bundle = Prompt.surface_bundle()

    assert bundle.tokenizer == "simple_words"
    assert bundle.token_budget == 1_000
    assert bundle.within_budget?
    assert bundle.token_count < 1_000
    assert Enum.map(bundle.tools, & &1.name) == ~w(read grep glob write edit bash)
    assert bundle.system_prompt =~ "AGENTS.md hierarchy"
  end

  test "coding slash set is allowlisted but not registered as routable actions" do
    assert "/pi" in SlashCommands.canonical_commands()
    assert "/mode" in SlashCommands.canonical_commands()
    assert "/model" in SlashCommands.canonical_commands()
    assert "/clear" in SlashCommands.canonical_commands()
    assert "/init" in SlashCommands.canonical_commands()
    assert "/diff" in SlashCommands.canonical_commands()
    assert "/compact" in SlashCommands.canonical_commands()

    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())

    for slash <- ["/pi", "/mode", "/model", "/clear", "/init", "/diff", "/compact"] do
      refute slash in agent_action_names
      assert {:error, {:unknown_action, ^slash}} = Registry.capability(slash)
    end
  end

  test "/pi pins cwd jail and /diff plus @file use bounded read action without model turns", %{
    repo: repo,
    other_repo: other_repo,
    link: link
  } do
    configure_tui!(repo)
    parent = self()

    assert {:ok, server} = start_tui(parent)

    assert {:ok, {:slash, [entered]}} =
             Adapter.submit(server, "/pi #{link}", external_event_id: "evt-m8-pi")

    assert {:ok, pinned_repo} = PathPolicy.jail(%{cwd_jail: repo})
    assert entered =~ "Pi-mode entered"
    assert entered =~ "cwd_jail=#{pinned_repo}"
    refute_event("evt-m8-pi")
    refute_received {:runtime_request, _request}

    assert {:ok, _setting} =
             Settings.put("coding.workspace.cwd_jail", other_repo, %{audit?: false})

    assert {:ok, {:slash, [diff]}} =
             Adapter.submit(server, "/diff sample.txt", external_event_id: "evt-m8-diff")

    assert diff =~ "Read-only diff context:"
    assert diff =~ "from pinned repo"
    refute diff =~ "from changed setting"
    refute_event("evt-m8-diff")
    refute_received {:runtime_request, _request}

    assert {:ok, {:at_file, [file_read]}} =
             Adapter.submit(server, "@sample.txt", external_event_id: "evt-m8-at-file")

    assert file_read =~ "from pinned repo"
    refute file_read =~ "from changed setting"
    refute_event("evt-m8-at-file")
    refute_received {:runtime_request, _request}
  end

  test "/mode /model /clear /compact mutate only Pi-mode session state", %{repo: repo} do
    configure_tui!(repo)
    parent = self()

    assert {:ok, server} = start_tui(parent)
    assert {:ok, {:slash, [_entered]}} = Adapter.submit(server, "/pi #{repo}")

    for {command, expected} <- [
          {"/mode plan", "Pi-mode approval mode switched to plan."},
          {"/mode", "Pi-mode approval mode: plan."},
          {"/model coding_local", "Pi-mode model switched to coding_local."},
          {"/model", "Pi-mode model: coding_local."},
          {"/clear", "Pi-mode context cleared."},
          {"/compact", "Pi-mode context compacted."}
        ] do
      assert {:ok, {:slash, [rendered]}} = Adapter.submit(server, command)
      assert rendered == expected
      refute_received {:runtime_request, _request}
    end
  end

  test "/init writes only through coding file-write confirmation gate", %{repo: repo} do
    configure_tui!(repo)
    parent = self()

    assert {:ok, server} = start_tui(parent)
    assert {:ok, {:slash, [_entered]}} = Adapter.submit(server, "/pi #{repo}")

    assert {:ok, {:slash, [plan_rendered]}} = Adapter.submit(server, "/mode plan")
    assert plan_rendered == "Pi-mode approval mode switched to plan."

    assert {:ok, {:slash, [denied]}} = Adapter.submit(server, "/init plan-denied.md")
    assert denied =~ "permission gate returned denied"
    refute File.exists?(Path.join(repo, "plan-denied.md"))

    assert {:ok, {:slash, [default_rendered]}} = Adapter.submit(server, "/mode default")
    assert default_rendered == "Pi-mode approval mode switched to default."

    assert {:ok, {:slash, [rendered]}} =
             Adapter.submit(server, "/init pi-init.md", external_event_id: "evt-m8-init")

    assert rendered =~ "Approval:"
    assert rendered =~ "target=write"
    assert [_, confirmation_id] = Regex.run(~r/ALLBERT:APPROVE:([A-Za-z0-9_-]+)/, rendered)
    refute File.exists?(Path.join(repo, "pi-init.md"))
    refute_event("evt-m8-init")
    refute_received {:runtime_request, _request}

    assert {:ok, {:processed, event, [approval_rendered]}} =
             Adapter.submit(server, "ALLBERT:APPROVE:#{confirmation_id}",
               external_event_id: "evt-m8-init-approve"
             )

    assert event.direction == "callback"
    assert event.status == "processed"
    assert approval_rendered =~ "approved"
    assert File.exists?(Path.join(repo, "pi-init.md"))

    assert {:ok, approved} = Confirmations.read(confirmation_id)
    assert approved["status"] == "approved"
    assert get_in(approved, ["operator_resolution", "target_resumed?"]) == true
    refute_received {:runtime_request, _request}
  end

  test "ReqLLM context merge survives model switch for the session", %{repo: repo} do
    configure_tui!(repo)

    assert {:ok, session} = CodingSession.start(repo, %{operator_id: "alice"})
    assert length(session.req_llm_context.messages) == 1

    assert Enum.map(session.req_llm_context.tools, & &1.name) ==
             ~w(read grep glob write edit bash)

    response = %ReqLLM.Response{
      id: "resp-m8",
      model: "fixture",
      context: nil,
      message: ReqLLM.Context.assistant("hello")
    }

    assert {:ok, merged_session, updated_response} =
             CodingSession.merge_response(session, response)

    assert %ReqLLM.Context{} = updated_response.context
    assert length(merged_session.req_llm_context.messages) == 2

    assert {:ok, switched} = CodingSession.switch_model(merged_session, "coding_local")
    assert switched.model_profile == "coding_local"
    assert length(switched.req_llm_context.messages) == 2

    cleared = CodingSession.clear(switched)
    assert length(cleared.req_llm_context.messages) == 1

    assert Enum.map(cleared.req_llm_context.tools, & &1.name) ==
             ~w(read grep glob write edit bash)
  end

  defp configure_tui!(repo) do
    assert {:ok, _setting} = Settings.put("channels.tui.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.tui.identity_map",
               [%{"external_user_id" => "default", "user_id" => "alice", "enabled" => true}],
               %{audit?: false}
             )

    assert {:ok, _setting} = Settings.put("coding.pi_mode.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("coding.trusted_operator_id", "alice", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("coding.default_approval_mode", "default", %{audit?: false})

    assert {:ok, _setting} = Settings.put("coding.workspace.cwd_jail", repo, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("coding.model_profile", "pi_coding_local", %{audit?: false})
  end

  defp start_tui(parent) do
    Adapter.start_link(
      name: nil,
      auto_input?: false,
      enabled?: true,
      live_screen?: false,
      output_fun: fn line -> send(parent, {:tui_output, line}) end
    )
  end

  defp refute_event(external_event_id) do
    refute Repo.get_by(Event, channel: "tui", external_event_id: external_event_id)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end
end
