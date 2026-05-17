defmodule AllbertAssistWeb.ObjectiveLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Objectives

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
    assert has_element?(view, "#objective-header")
    assert has_element?(view, "#objective-step-#{step.id}")
    assert has_element?(view, "#objective-events")
    assert has_element?(view, "#objective-cancel-button")
    assert has_element?(view, "#objective-continue-button")

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
end
