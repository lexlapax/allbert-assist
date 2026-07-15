defmodule AllbertAssist.Actions.BrowserResearchTurnTest do
  @moduledoc """
  v1.0.1 M4.2 — `browser_research_handoff` is the honest turn-level dispatcher
  to the real `research.specialist` delegate path, never an inert
  `:completed` advisory.
  """

  use AllbertAssist.DataCase, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AgentRegistry
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
        "allbert-browser-research-turn-#{System.unique_integer([:positive])}"
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

  describe "wired delegate path (browser + research enabled, Stub driver)" do
    setup do
      assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})
      assert {:ok, _setting} = Settings.put("research.enabled", true, %{audit?: false})
      :ok
    end

    test "creates an objective with a delegate_agent step targeting research.specialist" do
      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{url: "https://example.com/docs/a"},
                 %{user_id: "alice", operator_id: "alice", active_app: :allbert_browser}
               )

      # The unapproved browser session start blocks on the existing
      # confirmation machinery — the turn must not claim completion.
      assert response.status == :needs_confirmation
      refute response.status == :completed
      assert is_binary(response.confirmation_id)
      assert response.message =~ "waiting for your approval"
      assert response.message =~ "Research app"

      assert [objective] = Objectives.list_objectives("alice", status: "blocked", limit: 1)
      assert objective.source_intent == "browser_research_handoff"
      assert objective.title == "research.specialist"
      assert response.objective_id == objective.id
      assert response.message =~ objective.id

      assert [step] = Objectives.list_steps(objective.id)
      assert step.kind == "delegate_agent"
      assert step.delegate_agent_id == "research.specialist"
      assert step.status == "blocked"
      assert step.confirmation_id == response.confirmation_id
    end

    test "grant-backed session-approved research completes through the delegate" do
      # Pre-approve the session + navigation the way the CLI smoke does, so the
      # delegate runs to completion against the Stub driver.
      remember_navigation_grant!("https://example.com/docs/")

      assert {:ok, doctor} = Runner.run("browser_doctor", %{}, %{})
      assert doctor.doctor.live_check_status == :ok

      assert {:ok, started} =
               Runner.run("browser_start_session", %{}, %{confirmation: %{approved?: true}})

      assert started.status == :completed

      # Feed the session to the delegate through the shared machinery the
      # action wraps, then assert the turn action reports honestly.
      assert {:ok, run} =
               AllbertResearch.DelegateObjective.start("alice", "https://example.com/docs/a",
                 session_id: started.session_id,
                 source_intent: "browser_research_handoff",
                 trace_prefix: "browser_research_turn_test"
               )

      assert run.status == :completed
      assert run.command == :summarize_url
      assert run.objective.status == "completed"

      assert [%{source_intent: "browser_research_handoff"}] =
               Objectives.list_objectives("alice", status: "completed", limit: 1)
    end

    test "extracts the research URL from the turn text when no url param is routed" do
      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{},
                 %{
                   user_id: "alice",
                   operator_id: "alice",
                   active_app: :allbert_browser,
                   source_text: "research the official Elixir website at https://elixir-lang.org"
                 }
               )

      assert response.status == :needs_confirmation
      assert [objective] = Objectives.list_objectives("alice", status: "blocked", limit: 1)
      assert objective.objective =~ "https://elixir-lang.org"
    end

    test "asks for a URL instead of fabricating one when the prompt names no site" do
      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{},
                 %{
                   user_id: "alice",
                   operator_id: "alice",
                   active_app: :allbert_browser,
                   source_text: "Research the official Elixir website"
                 }
               )

      assert response.status == :stopped
      refute response.status == :completed
      assert response.error == :missing_research_url
      assert response.message =~ "URL"
      assert Objectives.list_objectives("alice", limit: 5) == []
    end
  end

  describe "honest blocked reporting (preconditions unmet)" do
    test "browser.enabled off (default) blocks with the exact setting named" do
      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{url: "https://example.com/docs/a"},
                 %{user_id: "alice", operator_id: "alice", active_app: :allbert_browser}
               )

      assert response.status == :stopped
      refute response.status == :completed
      assert response.error == :browser_disabled
      assert response.message =~ "browser.enabled"
      assert Objectives.list_objectives("alice", limit: 5) == []
    end

    test "research.enabled off blocks with the exact setting named" do
      assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})

      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{url: "https://example.com/docs/a"},
                 %{user_id: "alice", operator_id: "alice", active_app: :allbert_browser}
               )

      assert response.status == :stopped
      assert response.error == :research_disabled
      assert response.message =~ "research.enabled"
      assert Objectives.list_objectives("alice", limit: 5) == []
    end

    test "unregistered research delegate blocks honestly" do
      assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})
      assert {:ok, _setting} = Settings.put("research.enabled", true, %{audit?: false})
      AgentRegistry.unregister(AllbertResearch.Runtime.agent_id())

      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{url: "https://example.com/docs/a"},
                 %{user_id: "alice", operator_id: "alice", active_app: :allbert_browser}
               )

      assert response.status == :stopped
      assert response.error == :research_agent_unavailable
      assert response.message =~ "research.specialist"
      assert Objectives.list_objectives("alice", limit: 5) == []
    end
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
