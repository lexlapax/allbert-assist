defmodule AllbertAssistWeb.ObjectiveLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.Surface.Catalog
  alias AllbertAssist.TestSupport.FanoutReportFixture
  alias AllbertAssist.TestSupport.ReadyEffectContext

  test "renders objective details and cancels through registered action", %{conn: conn} do
    assert {:ok, objective} =
             Objectives.create_objective(
               %{
                 user_id: "local",
                 title: "Analyze AAPL",
                 objective: "Complete one analysis for AAPL.",
                 status: "blocked",
                 active_app: "stocksage",
                 acceptance_criteria: %{"min_completed_steps" => 1}
               },
               ReadyEffectContext.context()
             )

    assert {:ok, step} =
             Objectives.create_step(
               %{
                 objective_id: objective.id,
                 kind: "action",
                 status: "blocked",
                 stage: "authorize_step",
                 candidate_action: "StockSage.Actions.RunAnalysis",
                 confirmation_id: "conf_live_objective"
               },
               ReadyEffectContext.context()
             )

    assert {:ok, _event} =
             Objectives.create_event(
               %{
                 objective_id: objective.id,
                 step_id: step.id,
                 kind: "blocked",
                 summary: "Waiting for confirmation."
               },
               ReadyEffectContext.context()
             )

    {:ok, view, html} = live(conn, ~p"/objectives/#{objective.id}")

    assert html =~ "Analyze AAPL"
    assert has_element?(view, "#operator-shell[data-active-page='objectives']")
    assert has_element?(view, "#objective-header")
    assert has_element?(view, "#objective-header [data-workspace-component='objective_card']")
    assert_catalog_components_known!(html)
    assert has_element?(view, "#objective-step-#{step.id}")
    assert has_element?(view, "#objective-events")
    assert has_element?(view, "#objective-cancel-button")
    assert has_element?(view, "#objective-cancel-button[data-workspace-component='button']")
    assert has_element?(view, "#objective-continue-button")
    assert html =~ "Min Completed Steps:"
    assert html =~ ~r/>\s*1\s*</
    assert html =~ "Current step: blocked action #{step.id}"
    refute html =~ ~s(%{"min_completed_steps" => 1})
    refute html =~ "Current step: none"

    view
    |> element("#objective-cancel-button")
    |> render_click()

    cancel_html =
      view
      |> form("#objective-cancel-modal", %{reason: "operator cancelled from test"})
      |> render_submit()

    assert cancel_html =~ "Objective #{objective.id} cancelled"

    assert {:ok, cancelled} = Objectives.get_objective(objective.id)
    assert cancelled.status == "cancelled"

    [cancelled_step] = Objectives.list_steps(objective.id)
    assert cancelled_step.status == "cancelled"
  end

  test "renders missing, terminal, and refreshed objective states", %{conn: conn} do
    assert {:ok, objective} =
             Objectives.create_objective(
               %{
                 user_id: "local",
                 title: "Terminal objective",
                 objective: "Already abandoned.",
                 status: "abandoned"
               },
               ReadyEffectContext.context()
             )

    {:ok, view, html} = live(conn, ~p"/objectives/#{objective.id}")
    assert has_element?(view, "#operator-shell[data-active-page='objectives']")
    assert has_element?(view, "#objective-header [data-workspace-component='objective_card']")
    assert_catalog_components_known!(html)
    assert html =~ "Terminal objective"
    assert html =~ "abandoned"
    refute has_element?(view, "#objective-cancel-button")

    assert {:ok, _objective} =
             Objectives.update_objective(
               objective,
               %{status: "cancelled"},
               ReadyEffectContext.context()
             )

    send(view.pid, {:objective_event, %{type: "allbert.objective.cancelled"}})
    assert render(view) =~ "cancelled"

    {:ok, _missing_view, missing_html} = live(conn, ~p"/objectives/obj_missing_live")
    assert missing_html =~ "Objective not found."
    assert missing_html =~ ~s(data-workspace-component="empty_state")
    assert_catalog_components_known!(missing_html)

    assert {:ok, other_user} =
             Objectives.create_objective(
               %{
                 user_id: "alice",
                 title: "Alice only",
                 objective: "Should not leak."
               },
               ReadyEffectContext.context()
             )

    {:ok, _cross_view, cross_html} = live(conn, ~p"/objectives/#{other_user.id}")
    assert cross_html =~ "Objective not found."
    refute cross_html =~ "Alice only"
  end

  test "embeds Plan/Build run progress for workflow objectives", %{conn: conn} do
    assert {:ok, objective} =
             Objectives.create_objective(
               %{
                 user_id: "local",
                 title: "Run workflow",
                 objective: "Execute the multi_step workflow.",
                 status: "running",
                 active_app: "allbert",
                 source_intent: "workflow:multi_step:1"
               },
               ReadyEffectContext.context()
             )

    assert {:ok, step} =
             Objectives.create_step(
               %{
                 objective_id: objective.id,
                 kind: "delegate_agent",
                 status: "running",
                 stage: "execute_step",
                 provider: "plan_build",
                 candidate_action: "delegate_agent",
                 delegate_agent_id: "plan-build-stub"
               },
               ReadyEffectContext.context()
             )

    assert {:ok, _event} =
             Objectives.create_event(
               %{
                 objective_id: objective.id,
                 step_id: step.id,
                 kind: "observed",
                 summary: "Parent step started."
               },
               ReadyEffectContext.context()
             )

    assert {:ok, _child_event} =
             Objectives.create_event(
               %{
                 objective_id: objective.id,
                 kind: "observed",
                 summary: "Child agent reported progress.",
                 payload: %{parent_step_id: step.id}
               },
               ReadyEffectContext.context()
             )

    {:ok, view, html} = live(conn, ~p"/objectives/#{objective.id}")

    assert has_element?(view, "#operator-shell[data-active-page='objectives']")
    assert html =~ ~s(data-workspace-component="plan_run_progress_panel")
    assert_catalog_components_known!(html)
    assert html =~ "workflow:multi_step:1"
    assert html =~ "delegate_agent"
    assert html =~ "Subagent events"
    assert html =~ "Child agent reported progress."

    cancel_html =
      view
      |> element(~s([data-workspace-component="plan_run_progress_panel"] button), "Cancel plan")
      |> render_click()

    assert cancel_html =~ "Objective #{objective.id} cancelled"
    assert {:ok, cancelled} = Objectives.get_objective(objective.id)
    assert cancelled.status == "cancelled"
  end

  test "workspace fragment/event messages on the shared user topic do not crash the view", %{
    conn: conn
  } do
    assert {:ok, objective} =
             Objectives.create_objective(
               %{
                 user_id: "local",
                 title: "Shared topic objective",
                 objective: "Stay alive through fragment traffic.",
                 status: "running",
                 active_app: "allbert",
                 acceptance_criteria: %{"min_completed_steps" => 1}
               },
               ReadyEffectContext.context()
             )

    {:ok, view, _html} = live(conn, ~p"/objectives/#{objective.id}")

    # SignalBridge broadcasts these to topic_for("local"), which this view subscribes
    # to for objective events; unmatched handle_info would crash the process.
    send(view.pid, {:fragment, %{}})
    send(view.pid, {:workspace_event, %{}})

    assert render(view) =~ "Shared topic objective"
    assert Process.alive?(view.pid)
  end

  test "renders a live fan-out tree and steers a child through the registered action", %{
    conn: conn
  } do
    assert {:ok, %{parent: parent, children: [first, second]}} =
             Fanout.frame(
               ReadyEffectContext.attach(%{
                 user_id: "local",
                 title: "Parallel launch",
                 objective: "Parallel launch"
               }),
               ["Research risks", "Draft brief"]
             )

    {:ok, view, html} = live(conn, ~p"/objectives/#{parent.id}")
    assert html =~ "Fan-out tasks"
    assert has_element?(view, "#fanout-child-#{first.id}")
    assert has_element?(view, "#fanout-child-#{second.id}")

    html =
      view
      |> form("#fanout-child-#{first.id} form", %{
        "child-id" => first.id,
        "directive" => "Use primary sources"
      })
      |> render_submit()

    assert html =~ "Steering queued"
    assert {:ok, steered} = Objectives.get_objective(first.id)
    assert Enum.any?(Objectives.list_events(steered.id), &(&1.kind == "steer_directive"))
  end

  test "rejects tampered child ids from another fan-out", %{conn: conn} do
    assert {:ok, %{parent: parent}} =
             Fanout.frame(
               ReadyEffectContext.attach(%{
                 user_id: "local",
                 title: "Visible launch",
                 objective: "Visible launch"
               }),
               ["Visible research", "Visible draft"]
             )

    assert {:ok, %{children: [foreign | _]}} =
             Fanout.frame(
               ReadyEffectContext.attach(%{
                 user_id: "local",
                 title: "Other launch",
                 objective: "Other launch"
               }),
               ["Other research", "Other draft"]
             )

    {:ok, view, _html} = live(conn, ~p"/objectives/#{parent.id}")

    assert render_hook(view, "steer_fanout_child", %{
             "child-id" => foreign.id,
             "directive" => "Ignore the visible launch"
           }) =~ "That fan-out task is not active in this objective."

    assert Objectives.list_events(foreign.id) == []

    assert render_hook(view, "cancel_fanout_child", %{"child-id" => foreign.id}) =~
             "That fan-out task is not active in this objective."

    assert {:ok, unchanged} = Objectives.get_objective(foreign.id)
    assert unchanged.status == "open"
    assert Objectives.list_events(foreign.id) == []
  end

  test "stopping a fan-out preserves finished work and renders the partial outcome", %{conn: conn} do
    assert {:ok, %{parent: parent, children: [completed, active]}} =
             Fanout.frame(
               ReadyEffectContext.attach(%{
                 user_id: "local",
                 title: "Partially finished launch",
                 objective: "Join two tasks"
               }),
               ["Finished research", "Active draft"]
             )

    FanoutReportFixture.complete_child!(completed, "Finished evidence is retained")

    {:ok, view, _html} = live(conn, ~p"/objectives/#{parent.id}")

    assert has_element?(view, "#objective-cancel-button", "Stop remaining work")

    cancel_html =
      view
      |> element("#objective-cancel-button")
      |> render_click()

    assert cancel_html =~ "Completed child results are preserved"
    assert cancel_html =~ "partial rather than cancelled"

    result_html =
      view
      |> form("#objective-cancel-modal", %{reason: "Enough evidence collected"})
      |> render_submit()

    assert result_html =~ "final outcome is completed/partial"
    assert result_html =~ "Finished evidence is retained"
    assert {:ok, %{status: "completed"}} = Objectives.get_objective(completed.id)
    assert {:ok, %{status: "cancelled"}} = Objectives.get_objective(active.id)

    assert {:ok, %{status: "completed", join_outcome: "partial"}} =
             Objectives.get_objective(parent.id)

    refute has_element?(view, "#objective-cancel-button")
  end

  test "renders truthful joined child results without stale controls", %{conn: conn} do
    assert {:ok, %{parent: parent, children: [completed, failed]}} =
             Fanout.frame(
               ReadyEffectContext.attach(%{
                 user_id: "local",
                 title: "Joined launch",
                 objective: "Join two tasks"
               }),
               ["Completed research", "Failed draft"]
             )

    FanoutReportFixture.complete_child!(
      completed,
      "**Primary sources** reviewed " <> String.duplicate("detail ", 60) <> "TAIL"
    )

    assert {:ok, _transition} =
             TerminalTransitions.terminalize_child(
               failed,
               %{
                 status: "failed",
                 progress_summary: "stale draft progress",
                 review_reason: "Provider became unavailable",
                 completed_at: DateTime.utc_now()
               },
               "run_failed",
               %{},
               effect_context: ReadyEffectContext.context()
             )

    {:ok, view, html} = live(conn, ~p"/objectives/#{parent.id}")

    assert html =~ "Primary sources reviewed"
    assert html =~ "Provider became unavailable"
    assert html =~ "Result preview"
    assert html =~ "…"
    refute html =~ "**Primary sources**"
    refute html =~ "TAIL"
    refute html =~ "stale draft progress"
    assert has_element?(view, "#fanout-child-#{completed.id} [data-preview-kind='result']")
    assert has_element?(view, "#fanout-child-#{failed.id} [data-preview-kind='result']")

    assert has_element?(
             view,
             "#fanout-child-#{completed.id} a[href='/objectives/#{completed.id}']",
             "Open task"
           )

    assert has_element?(
             view,
             "#fanout-child-#{failed.id} a[href='/objectives/#{failed.id}']",
             "Open task"
           )

    refute has_element?(view, "#fanout-child-#{completed.id} form")
    refute has_element?(view, "#fanout-child-#{failed.id} form")
    refute has_element?(view, "#objective-cancel-button")
  end

  defp assert_catalog_components_known!(html) do
    known_components = Catalog.known_components() |> Enum.map(&Atom.to_string/1)

    rendered_components =
      ~r/data-workspace-component="([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert rendered_components != []
    assert Enum.all?(rendered_components, &(&1 in known_components))
  end
end
