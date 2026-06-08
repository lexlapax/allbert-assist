defmodule AllbertAssist.Plugins.Telegram.RendererTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Channels.Telegram.Renderer
  alias AllbertAssist.Objectives

  test "normal response rendering includes redacted media-output fallbacks" do
    assert {:ok, [text], nil} =
             Renderer.render_response(%{
               message: "Image generated.",
               media_outputs: [
                 %{
                   kind: :image,
                   source_action: "generate_image",
                   local_path: "/tmp/allbert-secret/image.png",
                   resource_uri: "file://[REDACTED_IMAGE_PATH]",
                   mime_type: "image/png"
                 }
               ]
             })

    assert text =~ "Image generated."
    assert text =~ "Media outputs:"
    assert text =~ "- image image/png file://[REDACTED_IMAGE_PATH] generate_image"
    refute text =~ "/tmp/allbert-secret"
  end

  test "approval handoff rendering includes objective context and stale warning" do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               status: "running"
             })

    handoff = %{
      confirmation_id: "conf_tg_objective",
      objective_id: objective.id,
      step_id: "step_tg_objective",
      params_summary: %{
        objective_id: objective.id,
        objective_title: "Analyze AAPL",
        objective_status: "running"
      },
      summary: "Run StockSage analysis."
    }

    assert {:ok, _objective} = Objectives.update_objective(objective, %{status: "cancelled"})

    assert {:ok, [text], keyboard} = Renderer.render_approval_handoff(handoff)

    assert text =~ "Objective: #{objective.id}"
    assert text =~ "Step: step_tg_objective"
    assert text =~ "Note: objective is now :cancelled"
    assert %{"inline_keyboard" => buttons} = keyboard

    assert List.flatten(buttons)
           |> Enum.any?(&(&1["callback_data"] == "allbert:v1:show:conf_tg_objective"))
  end
end
