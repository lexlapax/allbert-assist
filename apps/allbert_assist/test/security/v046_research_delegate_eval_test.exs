defmodule AllbertAssist.Security.V046ResearchDelegateEvalTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :security_eval_serial
  @moduletag :home_fs_serial
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Objectives.Engine.Agent, as: EngineAgent
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Resources.{Grants, Ref, ResourceURI, Scope}
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertBrowser.Session

  @eval_ids [
    "delegation-does-not-widen-authority-001",
    "research-navigation-still-confirms-001",
    "research-output-advisory-not-authority-001",
    "research-no-memory-autopromote-001",
    "research-max-sources-cap-001",
    "research-inherits-browser-grant-scope-001",
    "research-session-always-closed-001",
    "delegate-agent-isolation-001",
    "delegate-command-allowlist-enforced-via-objective-001"
  ]

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_memory_config = Application.get_env(:allbert_assist, AllbertAssist.Memory)
    original_driver = Application.get_env(:allbert_browser, :driver)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v046-research-eval-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, AllbertAssist.Memory, root: Path.join(root, "memory"))
    Application.put_env(:allbert_browser, :driver, AllbertBrowser.Driver.Stub)

    PluginRegistry.clear()
    AppRegistry.clear()
    assert {:ok, "allbert.browser"} = PluginRegistry.register_module(AllbertBrowser.Plugin)
    assert {:ok, "allbert.research"} = PluginRegistry.register_module(AllbertResearch.Plugin)
    register_app!(AllbertAssist.App.CoreApp, :allbert)
    register_app!(AllbertBrowser.App, :allbert_browser)
    register_app!(AllbertResearch.App, :allbert_research)

    ensure_browser_supervisor()
    ensure_research_supervisor()
    close_all_sessions()

    assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("research.enabled", true, %{audit?: false})

    on_exit(fn ->
      close_all_sessions()
      AgentRegistry.unregister(AllbertResearch.Runtime.agent_id())
      PluginRegistry.clear()
      restore_default_plugins()
      AppRegistry.clear()
      restore_default_apps()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(AllbertAssist.Memory, original_memory_config)
      restore_env(:allbert_browser, :driver, original_driver)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "v0.46 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v046)

    assert Enum.map(rows, & &1.id) == @eval_ids
    assert Enum.all?(rows, &(&1.surface == :research_delegate))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "delegate metadata is advisory and isolated from StockSage" do
    assert_eval!("delegation-does-not-widen-authority-001")
    assert_eval!("delegate-agent-isolation-001")

    assert {:ok, research} = AgentRegistry.lookup(AllbertResearch.Runtime.agent_id())
    assert research.metadata.app_id == :allbert_research
    assert research.metadata.authority_surface == :none
    assert research.metadata.advisory?
    assert research.metadata.allowed_commands == [:research, :summarize_url]
    refute ActionsRegistry.registered_module?(AllbertResearch.Commands.Research)
    refute ActionsRegistry.registered_module?(AllbertResearch.Commands.SummarizeUrl)

    stocksage = stocksage_delegate_metadata()

    assert stocksage.id == "stocksage.quality_gate"
    assert research.id == "research.specialist"
    assert stocksage.metadata.app_id == :stocksage
    assert research.metadata.app_id != stocksage.metadata.app_id
  end

  test "navigation confirmation and browser grant scope are inherited inside delegation" do
    assert_eval!("research-navigation-still-confirms-001")
    assert_eval!("research-inherits-browser-grant-scope-001")

    session_id = start_browser_session!()

    assert {:ok, pending} =
             run_delegate(:summarize_url, %{
               session_id: session_id,
               url: "https://example.com/docs/ungranted"
             })

    assert pending.status == :needs_confirmation
    assert is_binary(pending.confirmation_id)
    assert pending.delegate_response.output_data.sources == []
    assert "pending_confirmation=browser_navigate" in pending.delegate_response.output_data.notes
    assert {:ok, %{sessions: []}} = Runner.run("browser_list_sessions", %{}, %{})

    remember_navigation_grant!("https://example.com/docs/")
    session_id = start_browser_session!()

    assert {:ok, out_of_scope} =
             run_delegate(:summarize_url, %{
               session_id: session_id,
               url: "https://example.com/other/outside"
             })

    assert out_of_scope.status == :needs_confirmation
    assert is_binary(out_of_scope.confirmation_id)
    assert {:ok, %{sessions: []}} = Runner.run("browser_list_sessions", %{}, %{})
  end

  test "completed research output is advisory, capped, memory-inert, and closes sessions", %{
    root: root
  } do
    assert_eval!("research-output-advisory-not-authority-001")
    assert_eval!("research-no-memory-autopromote-001")
    assert_eval!("research-max-sources-cap-001")
    assert_eval!("research-session-always-closed-001")

    remember_navigation_grant!("https://example.com/docs/")
    assert {:ok, _setting} = Settings.put("research.max_sources", 2, %{audit?: false})
    before_memory = memory_files(root)
    session_id = start_browser_session!()

    assert {:ok, completed} =
             run_delegate(:research, %{
               session_id: session_id,
               sources: [
                 "https://example.com/docs/a",
                 "https://example.com/docs/b",
                 "https://example.com/docs/c"
               ],
               max_sources: 10
             })

    assert completed.status == :completed
    assert completed.delegate_response.status == :completed
    assert completed.delegate_response.summary =~ "Research summary from 2 source"

    packet = completed.delegate_response.output_data
    assert length(packet.sources) == 2

    assert packet.notes == [
             "summary_engine=extractive_fallback",
             "session_closed",
             "advisory_only"
           ]

    assert [%{name: "research.specialist", advisory: true, source_count: 2}] =
             completed.delegate_response.actions

    refute Enum.any?(completed.delegate_response.actions, &(&1.name == "append_memory"))
    assert memory_files(root) == before_memory
    assert {:ok, %{sessions: []}} = Runner.run("browser_list_sessions", %{}, %{})
  end

  test "objective delegate execution rejects commands outside research metadata" do
    assert_eval!("delegate-command-allowlist-enforced-via-objective-001")

    engine_name = start_test_engine()

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Reject delegate command",
               objective: "Reject unsupported research command."
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "delegate_agent",
               status: "selected",
               stage: "execute_step",
               delegate_agent_id: AllbertResearch.Runtime.agent_id(),
               action_params: %{
                 command: "not_allowed",
                 params: %{url: "https://example.com/docs/a"}
               }
             })

    assert {:ok,
            %{objective: failed_objective, step: failed_step, result: result, status: :failed}} =
             EngineAgent.execute_step(engine_name, %{
               step_id: step.id,
               trace_id: "trace_v046_invalid_delegate_command"
             })

    assert failed_step.status == "failed"
    assert failed_objective.status == "failed"
    assert result.status == :error
    assert result.error == :invalid_delegate_command
  end

  defp assert_eval!(id), do: EvalInventory.row!(id)

  defp run_delegate(command, params) do
    objective_id = "obj_v046_#{System.unique_integer([:positive])}"
    step_id = "step_v046_#{System.unique_integer([:positive])}"

    Runner.run(
      "delegate_agent",
      %{
        user_id: "alice",
        objective_id: objective_id,
        step_id: step_id,
        delegate_agent_id: AllbertResearch.Runtime.agent_id(),
        command: Atom.to_string(command),
        params:
          Map.merge(
            %{
              user_id: "alice",
              objective_id: objective_id,
              step_id: step_id
            },
            params
          )
      },
      %{user_id: "alice", operator_id: "alice", surface: "v046_eval"}
    )
  end

  defp start_browser_session! do
    assert {:ok, doctor} = Runner.run("browser_doctor", %{}, %{})
    assert doctor.status == :completed
    assert doctor.doctor.live_check_status == :ok

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{confirmation: %{approved?: true}})

    assert started.status == :completed
    started.session_id
  end

  defp remember_navigation_grant!(url) do
    {:ok, resource_uri} = ResourceURI.url(url, :prefix)

    {:ok, ref} =
      Ref.new(%{
        resource_uri: resource_uri,
        origin_kind: :remote_url,
        operation_class: :browser_navigate,
        access_mode: :fetch,
        scope: Scope.url_prefix(resource_uri),
        downstream_consumer: :browser_navigator
      })

    assert {:ok, _grant} = Grants.remember(ref, audit?: false)
  end

  defp memory_files(root) do
    root
    |> Path.join("memory/**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  defp ensure_browser_supervisor do
    unless Process.whereis(AllbertBrowser.Supervisor) do
      start_supervised!(AllbertBrowser.Supervisor)
    end
  end

  defp ensure_research_supervisor do
    if Process.whereis(AllbertResearch.Supervisor) do
      AllbertResearch.Runtime.register_if_available(AllbertResearch.Agent, AllbertResearch.Agent)
    else
      start_supervised!(AllbertResearch.Supervisor)
    end
  end

  defp close_all_sessions do
    Enum.each(Session.list(), fn %{session_id: session_id} ->
      Session.close(session_id)
    end)
  end

  defp start_test_engine do
    name = :"objectives_engine_v046_#{System.unique_integer([:positive])}"
    start_supervised!({EngineAgent, name: name, id: Atom.to_string(name), child_id: name})
    name
  end

  defp stocksage_delegate_metadata do
    case AgentRegistry.lookup("stocksage.quality_gate") do
      {:ok, entry} ->
        entry

      {:error, :not_found} ->
        %{
          id: "stocksage.quality_gate",
          metadata:
            StockSage.Agents.spec!("stocksage.quality_gate")
            |> Map.take([:role, :prompt_file, :prompt_version, :type, :tool_modules, :tool_names])
            |> Map.put(:app_id, :stocksage)
        }
    end
  end

  defp restore_default_apps do
    _ = AppRegistry.register(AllbertAssist.App.CoreApp)
    _ = AppRegistry.register(StockSage.App)
    _ = AppRegistry.register(AllbertNotesFiles.App)
    _ = AppRegistry.register(AllbertBrowser.App)
    _ = AppRegistry.register(AllbertResearch.App)
  end

  defp restore_default_plugins do
    for module <- [
          AllbertAssist.Plugins.Telegram,
          AllbertAssist.Plugins.Email,
          AllbertNotesFiles.Plugin,
          AllbertBrowser.Plugin,
          AllbertResearch.Plugin,
          StockSage.Plugin
        ] do
      _ = PluginRegistry.register_module(module)
    end
  end

  defp register_app!(module, app_id) do
    case AppRegistry.register(module) do
      {:ok, ^app_id} -> :ok
      {:error, {:app_id_taken, ^app_id}} -> :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
  defp restore_env(module, key, nil), do: Application.delete_env(module, key)
  defp restore_env(module, key, value), do: Application.put_env(module, key, value)
end
