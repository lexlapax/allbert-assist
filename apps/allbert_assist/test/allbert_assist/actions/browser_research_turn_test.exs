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

  describe "live approval resume (M4.2.2, Stub driver, NO pre-remembered grant)" do
    setup do
      assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})
      assert {:ok, _setting} = Settings.put("research.enabled", true, %{audit?: false})
      :ok
    end

    test "approving the blocked confirmations resumes the delegate to a completed objective" do
      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{url: "https://example.com/docs/a"},
                 %{user_id: "alice", operator_id: "alice", active_app: :allbert_browser}
               )

      assert response.status == :needs_confirmation
      session_confirmation_id = response.confirmation_id
      objective_id = response.objective_id

      # Approve the browser session confirmation with the exact params the
      # operator surfaces (workspace/CLI) pass: only the confirmation id.
      assert {:ok, session_approval} =
               Runner.run("approve_confirmation", %{id: session_confirmation_id}, %{
                 actor: "alice",
                 user_id: "alice",
                 channel: :cli,
                 surface: "mix allbert.confirmations"
               })

      assert session_approval.status == :completed
      refute session_approval.confirmation["status"] == "adapter_unavailable"

      session_metadata = session_approval.actions |> hd() |> Map.get(:confirmation_metadata)
      assert session_metadata.target_resumed?
      refute Map.get(session_metadata, :adapter_unavailable?, false)

      # The approval re-drove the blocked delegate step; without a remembered
      # navigation grant the step now blocks on the navigation confirmation.
      assert session_approval.output_data.run_status == :needs_confirmation
      navigate_confirmation_id = session_approval.output_data.confirmation_id
      assert is_binary(navigate_confirmation_id)
      refute navigate_confirmation_id == session_confirmation_id

      assert {:ok, navigate_record} = Confirmations.read(navigate_confirmation_id)
      assert get_in(navigate_record, ["target_action", "name"]) == "browser_navigate"

      assert {:ok, blocked} = Objectives.get_objective(objective_id)
      assert blocked.status == "blocked"

      # Approve the navigation confirmation — the delegate re-drives to
      # completion against the Stub driver; no confirmation is skipped.
      assert {:ok, navigate_approval} =
               Runner.run("approve_confirmation", %{id: navigate_confirmation_id}, %{
                 actor: "alice",
                 user_id: "alice",
                 channel: :cli,
                 surface: "mix allbert.confirmations"
               })

      assert navigate_approval.status == :completed
      refute navigate_approval.confirmation["status"] == "adapter_unavailable"
      assert navigate_approval.output_data.run_status == :completed
      assert navigate_approval.output_data.summary =~ "Research summary"

      assert {:ok, completed} = Objectives.get_objective(objective_id)
      assert completed.status == "completed"

      assert [step] = Objectives.list_steps(objective_id)
      assert step.status == "completed"

      # The resolved confirmation carries the research result annotation.
      assert {:ok, resolved} = Confirmations.read(navigate_confirmation_id)
      assert resolved["status"] == "approved"

      assert get_in(resolved, ["operator_resolution", "target_result", "summary"]) =~
               "Research summary"

      # The delegate closed its session on the way out.
      assert {:ok, %{sessions: []}} = Runner.run("browser_list_sessions", %{}, %{})
    end

    test "workspace (live_view) approval resumes asynchronously and completes the objective" do
      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{url: "https://example.com/docs/a"},
                 %{user_id: "alice", operator_id: "alice", active_app: :allbert_browser}
               )

      assert response.status == :needs_confirmation
      objective_id = response.objective_id

      assert {:ok, session_approval} =
               Runner.run("approve_confirmation", %{id: response.confirmation_id}, %{
                 actor: "alice",
                 user_id: "alice",
                 channel: :liveview,
                 surface: "/workspace"
               })

      assert session_approval.status == :completed
      refute session_approval.confirmation["status"] == "adapter_unavailable"
      assert session_approval.output_data.run_status == :resuming

      # The async re-drive blocks on the navigation confirmation next.
      navigate_confirmation_id =
        eventually(fn ->
          case Objectives.get_objective(objective_id) do
            {:ok, %{status: "blocked"}} ->
              [step] = Objectives.list_steps(objective_id)

              if step.confirmation_id != response.confirmation_id do
                {:ok, step.confirmation_id}
              else
                :retry
              end

            _other ->
              :retry
          end
        end)

      assert {:ok, navigate_approval} =
               Runner.run("approve_confirmation", %{id: navigate_confirmation_id}, %{
                 actor: "alice",
                 user_id: "alice",
                 channel: :liveview,
                 surface: "/workspace"
               })

      assert navigate_approval.status == :completed
      assert navigate_approval.output_data.run_status == :resuming

      assert :ok ==
               eventually(fn ->
                 case Objectives.get_objective(objective_id) do
                   {:ok, %{status: "completed"}} -> {:ok, :ok}
                   _other -> :retry
                 end
               end)

      # The async re-drive annotated the resolved confirmation with the result.
      assert "Research summary" <> _rest =
               eventually(fn ->
                 with {:ok, resolved} <- Confirmations.read(navigate_confirmation_id),
                      summary when is_binary(summary) <-
                        get_in(resolved, ["operator_resolution", "target_result", "summary"]) do
                   {:ok, summary}
                 else
                   _other -> :retry
                 end
               end)
    end

    test "standalone browser session confirmation approval resumes only the session target" do
      assert {:ok, doctor} = Runner.run("browser_doctor", %{}, %{})
      assert doctor.doctor.live_check_status == :ok

      assert {:ok, pending} =
               Runner.run("browser_start_session", %{purpose: "standalone approval"}, %{
                 actor: "alice",
                 user_id: "alice",
                 channel: :cli
               })

      assert pending.status == :needs_confirmation

      assert {:ok, approval} =
               Runner.run("approve_confirmation", %{id: pending.confirmation_id}, %{
                 actor: "alice",
                 user_id: "alice",
                 channel: :cli
               })

      assert approval.status == :completed
      refute approval.confirmation["status"] == "adapter_unavailable"

      metadata = approval.actions |> hd() |> Map.get(:confirmation_metadata)
      assert metadata.target_resumed?
      assert metadata.target_status == :completed

      # Exactly the approved target ran: one session, no objective created.
      assert {:ok, %{sessions: [_session]}} = Runner.run("browser_list_sessions", %{}, %{})
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

  defp eventually(fun, attempts \\ 200) do
    case fun.() do
      {:ok, value} ->
        value

      :retry when attempts > 1 ->
        Process.sleep(25)
        eventually(fun, attempts - 1)

      :retry ->
        flunk("condition was not met before the eventually/2 deadline")
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
