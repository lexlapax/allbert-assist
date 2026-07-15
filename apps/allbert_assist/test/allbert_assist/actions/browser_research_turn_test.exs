defmodule AllbertAssist.Actions.BrowserResearchTurnTest do
  @moduledoc """
  v1.0.1 M4.2/M4.2.3 — `browser_research_handoff` is the honest turn-level
  dispatcher to the real `research.specialist` delegate path behind ONE
  up-front operator consent gate (mirroring `start_plan_run`): the turn raises
  a single confirmation carrying the `browser_navigate` url-prefix resource
  ref; operator approval records the durable navigation grant through the
  existing `GrantHandoff` machinery and re-runs the action once, server-side,
  to completion — no mid-flight confirmations, no step-bound vouchers.
  """

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

  describe "up-front consent gate (M4.2.3, preconditions pass, Stub driver)" do
    setup do
      assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})
      assert {:ok, _setting} = Settings.put("research.enabled", true, %{audit?: false})
      :ok
    end

    test "raises ONE consent confirmation carrying the navigation resource ref, no objective yet" do
      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{url: "https://example.com/docs/a"},
                 %{
                   user_id: "alice",
                   operator_id: "alice",
                   channel: :cli,
                   active_app: :allbert_browser
                 }
               )

      assert response.status == :needs_confirmation
      refute response.status == :completed
      assert is_binary(response.confirmation_id)

      assert {:ok, record} = Confirmations.read(response.confirmation_id)
      assert get_in(record, ["target_action", "name"]) == "browser_research_handoff"
      assert record["target_permission"] == "browser_navigate"
      assert get_in(record, ["params_summary", "url"]) == "https://example.com/docs/a"
      assert get_in(record, ["params_summary", "remember_scope"]) == "url_prefix"

      assert [ref] = get_in(record, ["params_summary", "resource_refs"])
      assert ref["operation_class"] == "browser_navigate"
      assert ref["access_mode"] == "fetch"
      assert ref["downstream_consumer"] == "browser_navigator"
      assert get_in(ref, ["scope", "kind"]) == "url_prefix"
      assert get_in(ref, ["scope", "value"]) =~ "https://example.com/docs"

      assert get_in(record, ["resume_params_ref", "url"]) == "https://example.com/docs/a"

      # No work started before consent: no objective, no browser session.
      assert Objectives.list_objectives("alice", limit: 5) == []
      assert {:ok, %{sessions: []}} = Runner.run("browser_list_sessions", %{}, %{})
    end

    test "approval records the durable url-prefix grant and completes the delegate run with NO second confirmation" do
      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{url: "https://example.com/docs/a"},
                 %{
                   user_id: "alice",
                   operator_id: "alice",
                   channel: :cli,
                   active_app: :allbert_browser
                 }
               )

      assert response.status == :needs_confirmation
      confirmation_id = response.confirmation_id

      assert {:ok, approval} =
               Runner.run("approve_confirmation", %{id: confirmation_id}, %{
                 actor: "alice",
                 user_id: "alice",
                 channel: :cli,
                 surface: "mix allbert.confirmations"
               })

      assert approval.status == :completed
      refute approval.confirmation["status"] == "adapter_unavailable"

      # The operator approval recorded the durable url-prefix navigation grant
      # through the existing GrantHandoff machinery.
      assert {:ok, grant} =
               Grants.find_applicable(navigation_ref!("https://example.com/docs/a"),
                 permission: :browser_navigate,
                 context: %{}
               )

      assert get_in(grant, ["scope", "kind"]) == "url_prefix"

      # The approved re-run completed the whole bounded research run.
      assert approval.output_data.run_status == :completed
      assert approval.output_data.summary =~ "Research summary"

      assert [objective] = Objectives.list_objectives("alice", status: "completed", limit: 1)
      assert objective.source_intent == "browser_research_handoff"
      assert objective.title == "research.specialist"

      assert [step] = Objectives.list_steps(objective.id)
      assert step.kind == "delegate_agent"
      assert step.status == "completed"

      # ONE gate total: no other confirmation was raised mid-flight.
      assert [resolved] = Confirmations.list(status: :all)
      assert resolved["id"] == confirmation_id
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
                 %{
                   user_id: "alice",
                   operator_id: "alice",
                   channel: :liveview,
                   active_app: :allbert_browser
                 }
               )

      assert response.status == :needs_confirmation
      confirmation_id = response.confirmation_id

      assert {:ok, approval} =
               Runner.run("approve_confirmation", %{id: confirmation_id}, %{
                 actor: "alice",
                 user_id: "alice",
                 channel: :liveview,
                 surface: "/workspace"
               })

      assert approval.status == :completed
      refute approval.confirmation["status"] == "adapter_unavailable"
      assert approval.output_data.run_status == :resuming

      assert :ok ==
               eventually(fn ->
                 case Objectives.list_objectives("alice", status: "completed", limit: 1) do
                   [%{source_intent: "browser_research_handoff"}] -> {:ok, :ok}
                   _other -> :retry
                 end
               end)

      # The async re-run annotated the resolved confirmation with the result,
      # and raised no further confirmation.
      assert "Research summary" <> _rest =
               eventually(fn ->
                 with {:ok, resolved} <- Confirmations.read(confirmation_id),
                      summary when is_binary(summary) <-
                        get_in(resolved, ["operator_resolution", "target_result", "summary"]) do
                   {:ok, summary}
                 else
                   _other -> :retry
                 end
               end)

      assert [resolved] = Confirmations.list(status: :all)
      assert resolved["id"] == confirmation_id
    end

    test "extracts the research URL from the turn text and gates on it" do
      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{},
                 %{
                   user_id: "alice",
                   operator_id: "alice",
                   channel: :cli,
                   active_app: :allbert_browser,
                   source_text: "research the official Elixir website at https://elixir-lang.org"
                 }
               )

      assert response.status == :needs_confirmation

      assert {:ok, record} = Confirmations.read(response.confirmation_id)
      assert get_in(record, ["params_summary", "url"]) == "https://elixir-lang.org"
      assert Objectives.list_objectives("alice", limit: 5) == []
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

  describe "objective origin attribution (M4.2.3 piece 4)" do
    setup do
      assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})
      assert {:ok, _setting} = Settings.put("research.enabled", true, %{audit?: false})
      :ok
    end

    test "the delegate objective persists the originating channel and surface" do
      assert {:ok, response} =
               Runner.run(
                 "browser_research_handoff",
                 %{url: "https://example.com/docs/a"},
                 %{
                   user_id: "alice",
                   operator_id: "alice",
                   channel: :live_view,
                   surface: "/workspace",
                   active_app: :allbert_browser
                 }
               )

      assert response.status == :needs_confirmation

      assert {:ok, approval} =
               Runner.run("approve_confirmation", %{id: response.confirmation_id}, %{
                 actor: "alice",
                 user_id: "alice",
                 channel: :cli,
                 surface: "mix allbert.confirmations"
               })

      assert approval.status == :completed

      assert [objective] = Objectives.list_objectives("alice", limit: 1)
      # Attribution follows the ORIGIN of the request, not the approval surface.
      assert objective.source_channel == "live_view"
      assert objective.source_surface == "/workspace"
    end

    test "confirmations raised by objective-driven work carry the objective's origin channel/surface" do
      assert {:ok, objective} =
               Objectives.create_objective(%{
                 user_id: "alice",
                 title: "origin attribution",
                 objective: "Start a browser session from an objective step.",
                 status: "open",
                 source_channel: "live_view",
                 source_surface: "/workspace"
               })

      assert {:ok, step} =
               Objectives.create_step(%{
                 objective_id: objective.id,
                 kind: "action",
                 status: "selected",
                 stage: "execute_step",
                 candidate_action: "browser_start_session"
               })

      _ = EngineAgent.execute_step(%{step_id: step.id, trace_id: "origin_attribution_test"})

      assert [record] =
               Enum.filter(Confirmations.list(status: :pending), fn record ->
                 get_in(record, ["target_action", "name"]) == "browser_start_session"
               end)

      assert get_in(record, ["origin", "channel"]) == "live_view"
      assert get_in(record, ["origin", "surface"]) == "/workspace"
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

  defp navigation_ref!(url) do
    {:ok, resource_uri} = ResourceURI.url(url, :exact)
    {:ok, prefix_uri} = ResourceURI.url(url, :prefix)

    {:ok, ref} =
      Ref.new(%{
        resource_uri: resource_uri,
        origin_kind: :remote_url,
        operation_class: :browser_navigate,
        access_mode: :fetch,
        scope: Scope.url_prefix(prefix_uri),
        downstream_consumer: :browser_navigator
      })

    ref
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
