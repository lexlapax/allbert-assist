defmodule AllbertAssist.Actions.ResearchDelegateTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Objectives.Engine.Agent, as: EngineAgent
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Resources.{Grants, Ref, ResourceURI, Scope}
  alias AllbertAssist.Settings
  alias AllbertBrowser.Session

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_driver = Application.get_env(:allbert_browser, :driver)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v046-research-delegate-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_browser, :driver, AllbertBrowser.Driver.Stub)

    PluginRegistry.clear()
    assert {:ok, "allbert.browser"} = PluginRegistry.register_module(AllbertBrowser.Plugin)
    assert {:ok, "allbert.research"} = PluginRegistry.register_module(AllbertResearch.Plugin)

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
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(:allbert_browser, :driver, original_driver)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "research specialist registers with advisory metadata and allowed commands" do
    assert {:ok, entry} = AgentRegistry.lookup(AllbertResearch.Runtime.agent_id())
    assert entry.server == AllbertResearch.Agent
    assert entry.module == AllbertResearch.Agent
    assert entry.metadata.app_id == :allbert_research
    assert entry.metadata.advisory?
    assert entry.metadata.authority_surface == :none
    assert entry.metadata.allowed_commands == [:research, :summarize_url]
  end

  test "delegate dispatch propagates browser navigation confirmation" do
    assert_browser_ready!()
    session_id = start_browser_session!()

    assert {:ok, response} =
             Runner.run(
               "delegate_agent",
               %{
                 user_id: "alice",
                 objective_id: "obj_research_pending",
                 step_id: "step_research_pending",
                 delegate_agent_id: AllbertResearch.Runtime.agent_id(),
                 command: "research",
                 params: %{
                   user_id: "alice",
                   objective_id: "obj_research_pending",
                   step_id: "step_research_pending",
                   session_id: session_id,
                   url: "https://example.com/research/pending"
                 }
               },
               %{user_id: "alice", operator_id: "alice"}
             )

    assert response.status == :needs_confirmation
    assert is_binary(response.confirmation_id)
    assert response.delegate_response.status == :needs_confirmation
    assert response.delegate_response.confirmation_id == response.confirmation_id
    assert response.delegate_response.output_data.sources == []

    assert response.delegate_response.output_data.notes == [
             "pending_confirmation=browser_navigate",
             "advisory_only"
           ]
  end

  test "grant-backed research returns advisory packet, caps sources, and closes session" do
    assert_browser_ready!()
    session_id = start_browser_session!()

    url = "https://example.com/docs/a"
    remember_navigation_grant!("https://example.com/docs/")

    assert {:ok, response} =
             Runner.run(
               "delegate_agent",
               %{
                 user_id: "alice",
                 objective_id: "obj_research_completed",
                 step_id: "step_research_completed",
                 delegate_agent_id: AllbertResearch.Runtime.agent_id(),
                 command: "research",
                 params: %{
                   user_id: "alice",
                   objective_id: "obj_research_completed",
                   step_id: "step_research_completed",
                   session_id: session_id,
                   sources: [url, "https://example.com/docs/b"],
                   max_sources: 1
                 }
               },
               %{user_id: "alice", operator_id: "alice"}
             )

    assert response.status == :completed
    assert response.delegate_response.status == :completed
    assert response.delegate_response.summary =~ "Research summary from 1 source"

    packet = response.delegate_response.output_data
    assert packet.summary == response.delegate_response.summary
    assert [%{url: ^url, extract_ref: extract_ref, preview: preview}] = packet.sources
    assert extract_ref =~ "cache://browser/#{session_id}/"
    assert preview =~ "Stub browser extraction"

    assert packet.notes == [
             "summary_engine=extractive_fallback",
             "session_closed",
             "advisory_only"
           ]

    refute Enum.any?(response.delegate_response.actions, &(&1.name == "append_memory"))
    assert {:ok, %{sessions: []}} = Runner.run("browser_list_sessions", %{}, %{})
  end

  test "objective engine path rejects research commands outside delegate metadata" do
    engine_name = start_test_engine()

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Research reject",
               objective: "Reject an unsupported research delegate command."
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
               trace_id: "trace_research_reject"
             })

    assert failed_step.status == "failed"
    assert failed_step.result_summary =~ "Unable to delegate objective step"
    assert failed_objective.status == "failed"
    assert result.status == :error
    assert result.error == :invalid_delegate_command
  end

  defp assert_browser_ready! do
    assert {:ok, doctor} = Runner.run("browser_doctor", %{}, %{})
    assert doctor.status == :completed
    assert doctor.doctor.live_check_status == :ok
  end

  defp start_browser_session! do
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
    name = :"objectives_engine_research_#{System.unique_integer([:positive])}"
    start_supervised!({EngineAgent, name: name, id: Atom.to_string(name), child_id: name})
    name
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

  defp restore_env(module, key, nil), do: Application.delete_env(module, key)
  defp restore_env(module, key, value), do: Application.put_env(module, key, value)
  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
