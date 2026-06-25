defmodule AllbertAssistWeb.ObjectiveLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Objectives
  alias AllbertAssist.Surface.Catalog

  test "renders objective details and cancels through registered action", %{conn: conn} do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               status: "blocked",
               active_app: "stocksage",
               acceptance_criteria: %{"min_completed_steps" => 1}
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "blocked",
               stage: "authorize_step",
               candidate_action: "StockSage.Actions.RunAnalysis",
               confirmation_id: "conf_live_objective"
             })

    assert {:ok, _event} =
             Objectives.create_event(%{
               objective_id: objective.id,
               step_id: step.id,
               kind: "blocked",
               summary: "Waiting for confirmation."
             })

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
             Objectives.create_objective(%{
               user_id: "local",
               title: "Terminal objective",
               objective: "Already abandoned.",
               status: "abandoned"
             })

    {:ok, view, html} = live(conn, ~p"/objectives/#{objective.id}")
    assert has_element?(view, "#operator-shell[data-active-page='objectives']")
    assert has_element?(view, "#objective-header [data-workspace-component='objective_card']")
    assert_catalog_components_known!(html)
    assert html =~ "Terminal objective"
    assert html =~ "abandoned"
    refute has_element?(view, "#objective-cancel-button")

    assert {:ok, _objective} = Objectives.update_objective(objective, %{status: "cancelled"})
    send(view.pid, {:objective_event, %{type: "allbert.objective.cancelled"}})
    assert render(view) =~ "cancelled"

    {:ok, _missing_view, missing_html} = live(conn, ~p"/objectives/obj_missing_live")
    assert missing_html =~ "Objective not found."
    assert missing_html =~ ~s(data-workspace-component="empty_state")
    assert_catalog_components_known!(missing_html)

    assert {:ok, other_user} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Alice only",
               objective: "Should not leak."
             })

    {:ok, _cross_view, cross_html} = live(conn, ~p"/objectives/#{other_user.id}")
    assert cross_html =~ "Objective not found."
    refute cross_html =~ "Alice only"
  end

  test "embeds Plan/Build run progress for workflow objectives", %{conn: conn} do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "Run workflow",
               objective: "Execute the multi_step workflow.",
               status: "running",
               active_app: "allbert",
               source_intent: "workflow:multi_step:1"
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "delegate_agent",
               status: "running",
               stage: "execute_step",
               provider: "plan_build",
               candidate_action: "delegate_agent",
               delegate_agent_id: "plan-build-stub"
             })

    assert {:ok, _event} =
             Objectives.create_event(%{
               objective_id: objective.id,
               step_id: step.id,
               kind: "observed",
               summary: "Parent step started."
             })

    assert {:ok, _child_event} =
             Objectives.create_event(%{
               objective_id: objective.id,
               kind: "observed",
               summary: "Child agent reported progress.",
               payload: %{parent_step_id: step.id}
             })

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
