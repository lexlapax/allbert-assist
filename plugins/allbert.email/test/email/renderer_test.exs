defmodule AllbertAssist.Plugins.Email.RendererTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Channels.Email.Renderer
  alias AllbertAssist.Objectives

  test "approval handoff rendering includes objective context and stale warning" do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               status: "running"
             })

    handoff = %{
      confirmation_id: "conf_email_objective",
      objective_id: objective.id,
      step_id: "step_email_objective",
      params_summary: %{
        objective_id: objective.id,
        objective_title: "Analyze AAPL",
        objective_status: "running"
      },
      summary: "Run StockSage analysis."
    }

    assert {:ok, _objective} = Objectives.update_objective(objective, %{status: "cancelled"})

    assert {:ok, subject, body, nil} =
             Renderer.render_approval_handoff(handoff, subject: "Approval required")

    assert subject == "Re: Approval required"
    assert body =~ "Objective: #{objective.id}"
    assert body =~ "Step: step_email_objective"
    assert body =~ "Note: objective is now :cancelled"
    assert body =~ "ALLBERT:SHOW:conf_email_objective"
  end
end

