defmodule AllbertAssistWeb.PlanBuildLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Paths
  alias AllbertAssist.Surface.Node
  alias AllbertAssistWeb.Workspace.Components.{PlanPreviewPanel, PlanRunProgressPanel}

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join([
        System.tmp_dir!(),
        "allbert-plan-build-live",
        "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      ])

    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, Paths, home: home)
    File.rm_rf!(home)
    File.mkdir_p!(Path.join(home, "workflows"))
    copy_fixture!("multi_step", home)
    write_editable_fixture!(home)

    on_exit(fn ->
      restore_env("ALLBERT_HOME", original_home)
      restore_app_env(Paths, original_paths_config)
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "Plan Preview panel renders every contract field" do
    html =
      render_component(PlanPreviewPanel,
        id: "plan-preview",
        node: %Node{
          id: "plan-preview",
          component: :plan_preview_panel,
          props: %{
            workflow_id: "multi_step",
            inputs: %{"since" => "today"},
            registered_actions: ["expand_workflow", "preview_plan", "start_plan_run"],
            preview: preview_packet()
          }
        },
        renderer_context: %{user_id: "local", channel: :live_view},
        workspace_state: %{}
      )

    assert html =~ ~s(data-workspace-component="plan_preview_panel")
    assert html =~ "Multi-step read-only workflow."
    assert html =~ "Workflow"
    assert html =~ "Version"
    assert html =~ "Inputs"
    assert html =~ "Params"
    assert html =~ "Permission"
    assert html =~ "Safety floor"
    assert html =~ "Resources"
    assert html =~ "Estimated cost"
    assert html =~ "Confirmations required"
    assert html =~ "Subagent target"
    assert html =~ "Failure blast radius"
    assert html =~ "Authority gates"
    assert html =~ "expand_workflow, preview_plan, start_plan_run"
    assert html =~ "Open editor"
    refute html =~ ~s(name="inputs[since]")
  end

  test "Plan Preview editor expands and recomputes preview through registered action", %{
    conn: conn
  } do
    {:ok, view, html} =
      live_isolated(conn, AllbertAssistWeb.PlanBuildLiveTest.PreviewHostLive)

    assert html =~ "Open editor"

    view
    |> element("button", "Open editor")
    |> render_click()

    assert has_element?(view, "[data-plan-preview-editor-modal]")
    assert has_element?(view, ~s(input[name="inputs[topic]"]))

    view
    |> form("#plan-preview-editor-plan-preview", %{
      "inputs" => %{"topic" => "routing"},
      "edits" => %{
        "steps" => %{
          "first" => %{"enabled" => "true", "confirm" => "true", "order" => "2"},
          "second" => %{"enabled" => "false", "confirm" => "false", "order" => "3"},
          "question" => %{"enabled" => "true", "confirm" => "false", "order" => "1"}
        }
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ ~s(data-plan-preview-editor-modal)
    assert html =~ ~s(value="routing")
    assert html =~ "Workflow editable is ready for operator review."
    assert html =~ ~s(data-plan-preview-step="question")
    assert html =~ ~s(data-plan-preview-step="first")
    refute html =~ ~s(data-plan-preview-step="second")
    assert html =~ "Confirmations required"
    assert html =~ "true"
  end

  test "Run Progress panel renders ordered steps and nested subagent events" do
    steps = [
      %{
        id: "step_collect",
        kind: "action",
        status: "completed",
        candidate_action: "direct_answer"
      },
      %{
        id: "step_delegate",
        kind: "delegate_agent",
        status: "running",
        candidate_action: "delegate_agent",
        delegate_agent_id: "plan-build-stub"
      }
    ]

    events = [
      %{id: "evt_1", step_id: "step_collect", kind: "step_completed", summary: "Collected."},
      %{
        id: "evt_2",
        step_id: "child_1",
        kind: "observed",
        summary: "Child agent reported progress.",
        payload: %{"parent_step_id" => "step_delegate"}
      }
    ]

    html =
      render_component(PlanRunProgressPanel,
        id: "plan-progress",
        node: %Node{
          id: "plan-progress",
          component: :plan_run_progress_panel,
          props: %{
            objective: %{
              id: "obj_plan",
              title: "Workflow run",
              status: "running",
              source_intent: "workflow:multi_step:1"
            },
            steps: steps,
            events: events,
            registered_actions: ["cancel_plan_run", "list_plan_runs"]
          }
        },
        renderer_context: %{user_id: "local", channel: :live_view},
        workspace_state: %{}
      )

    assert html =~ ~s(data-workspace-component="plan_run_progress_panel")
    assert html =~ "Workflow run"
    assert html =~ "workflow:multi_step:1"
    assert html =~ "direct_answer"
    assert html =~ "delegate_agent"
    assert html =~ "Subagent events"
    assert html =~ "Child agent reported progress."
    assert html =~ ~s(phx-click="plan_build_cancel_run")
    assert html =~ "cancel_plan_run, list_plan_runs"
  end

  test "Run Progress panel renders research specialist browser events inline" do
    steps = [
      %{
        id: "step_research",
        kind: "delegate_agent",
        status: "running",
        candidate_action: "delegate_agent",
        delegate_agent_id: "research.specialist"
      }
    ]

    events = [
      %{
        id: "evt_nav",
        step_id: "browser_nav",
        kind: "browser_navigate",
        summary: "Browser navigated to https://example.com/docs/a.",
        payload: %{"parent_step_id" => "step_research", "url" => "https://example.com/docs/a"}
      },
      %{
        id: "evt_extract",
        step_id: "browser_extract",
        kind: "browser_extract",
        summary: "Browser extraction completed.",
        payload: %{"parent_step_id" => "step_research", "format" => "text"}
      }
    ]

    html =
      render_component(PlanRunProgressPanel,
        id: "plan-progress-research",
        node: %Node{
          id: "plan-progress-research",
          component: :plan_run_progress_panel,
          props: %{
            objective: %{
              id: "obj_research",
              title: "Research workflow",
              status: "running",
              source_intent: "workflow:research_delegate:1"
            },
            steps: steps,
            events: events,
            registered_actions: ["cancel_plan_run", "list_plan_runs"]
          }
        },
        renderer_context: %{user_id: "local", channel: :live_view},
        workspace_state: %{}
      )

    assert html =~ "Research workflow"
    assert html =~ "research.specialist"
    assert html =~ "Subagent events"
    assert html =~ "Browser navigated to https://example.com/docs/a."
    assert html =~ "Browser extraction completed."
  end

  test "workspace Plan/Build destinations render the expected panels", %{conn: conn} do
    {:ok, preview_view, preview_html} =
      live(conn, ~p"/workspace?destination=workspace:plan_build")

    assert has_element?(
             preview_view,
             "#workspace-shell[data-canvas-destination='workspace:plan_build']"
           )

    assert has_element?(
             preview_view,
             "#workspace-canvas[data-destination='workspace:plan_build']"
           )

    assert preview_html =~ ~s(data-workspace-component="plan_preview_panel")
    assert preview_html =~ "Plan/Build Preview"

    {:ok, runs_view, runs_html} = live(conn, ~p"/workspace?destination=workspace:plan_runs")

    assert has_element?(
             runs_view,
             "#workspace-shell[data-canvas-destination='workspace:plan_runs']"
           )

    assert has_element?(
             runs_view,
             "#workspace-canvas[data-destination='workspace:plan_runs']"
           )

    assert runs_html =~ ~s(data-workspace-component="plan_run_progress_panel")
    assert runs_html =~ "Run Progress"
  end

  test "Plan/Build Start run button dispatches without crashing the LiveView", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspace?destination=workspace:plan_build")

    assert html =~ ~s(phx-click="plan_build_start_run")

    # start_plan_run is confirmation-required; the event must be handled (surfacing a
    # confirmation handoff or an error), never raise an unmatched-handle_event crash.
    render_click(view, "plan_build_start_run", %{"workflow-id" => "multi_step"})

    assert Process.alive?(view.pid)
    assert render(view) =~ "workspace-shell"
  end

  defp preview_packet do
    %{
      workflow_id: "multi_step",
      workflow_version: 1,
      resolved_inputs: %{"since" => "today"},
      objective_title: "Multi-step read-only workflow.",
      step_count: 1,
      authority_gates: [%{ordinal: 0, gate: :workflow_run_start, scope: "workflow://multi_step"}],
      warnings: [],
      steps: [
        %{
          ordinal: 1,
          id: "collect",
          kind: :action,
          action_name: "direct_answer",
          params_summary: %{"text" => "List issues."},
          permission: :read_only,
          safety_floor: :allowed,
          resources_needed: [],
          estimated_cost: %{seconds: 1, tokens: 0, dollars: 0.0},
          confidence_tier: :green,
          confirmations_required: false,
          subagent_target: nil,
          failure_blast_radius: %{halts_at: 1, unreachable: []}
        }
      ]
    }
  end

  defp copy_fixture!(id, home) do
    File.cp!(
      Path.expand("../../../../allbert_assist/test/fixtures/v0.44/workflows/#{id}.yaml", __DIR__),
      Path.join([home, "workflows", "#{id}.yaml"])
    )
  end

  defp write_editable_fixture!(home) do
    File.write!(
      Path.join([home, "workflows", "editable.yaml"]),
      """
      id: editable
      version: 1
      description: Editable preview workflow.
      inputs:
        - name: topic
          type: string
          required: false
          default: "planning"
      steps:
        - id: first
          kind: action
          action: direct_answer
          params:
            text: "First ${inputs.topic}."
        - id: second
          kind: action
          action: direct_answer
          params:
            text: "Remove me."
        - id: question
          kind: ask_user
          prompt: "Continue?"
          options:
            - value: "yes"
              label: "Yes"
            - value: "no"
              label: "No"
      """
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end

defmodule AllbertAssistWeb.PlanBuildLiveTest.PreviewHostLive do
  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Surface.Node
  alias AllbertAssistWeb.Workspace.Components.PlanPreviewPanel

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       node: %Node{
         id: "plan-preview",
         component: :plan_preview_panel,
         props: %{
           workflow_id: "editable",
           inputs: %{"topic" => "planning"},
           registered_actions: ["expand_workflow", "preview_plan", "start_plan_run"],
           preview: preview_packet()
         }
       }
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={PlanPreviewPanel}
      id="plan-preview"
      node={@node}
      renderer_context={%{user_id: "local", channel: :live_view}}
      workspace_state={%{}}
    />
    """
  end

  defp preview_packet do
    %{
      workflow_id: "editable",
      workflow_version: 1,
      resolved_inputs: %{"topic" => "planning"},
      objective_title: "Editable preview workflow.",
      step_count: 3,
      authority_gates: [%{ordinal: 0, gate: :workflow_run_start, scope: "workflow://editable"}],
      warnings: [],
      steps: [
        %{
          ordinal: 1,
          id: "first",
          kind: :action,
          action_name: "direct_answer",
          params_summary: %{"text" => "First ${inputs.topic}."},
          permission: :read_only,
          safety_floor: :allowed,
          resources_needed: [],
          estimated_cost: %{seconds: 1, tokens: 0, dollars: 0.0},
          confidence_tier: :green,
          confirmations_required: false,
          subagent_target: nil,
          failure_blast_radius: %{halts_at: 1, unreachable: []}
        },
        %{
          ordinal: 2,
          id: "second",
          kind: :action,
          action_name: "direct_answer",
          params_summary: %{"text" => "Remove me."},
          permission: :read_only,
          safety_floor: :allowed,
          resources_needed: [],
          estimated_cost: %{seconds: 1, tokens: 0, dollars: 0.0},
          confidence_tier: :green,
          confirmations_required: false,
          subagent_target: nil,
          failure_blast_radius: %{halts_at: 2, unreachable: []}
        },
        %{
          ordinal: 3,
          id: "question",
          kind: :ask_user,
          action_name: "ask_user",
          params_summary: %{"prompt" => "Continue?"},
          permission: :read_only,
          safety_floor: :allowed,
          resources_needed: [],
          estimated_cost: %{seconds: 1, tokens: 0, dollars: 0.0},
          confidence_tier: :green,
          confirmations_required: false,
          subagent_target: nil,
          failure_blast_radius: %{halts_at: 3, unreachable: []}
        }
      ]
    }
  end
end
