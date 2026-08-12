defmodule AllbertAssist.Runtime.FanoutCallersTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  @root Path.expand("../../../../..", __DIR__)

  @callers %{
    "tui" => "apps/allbert_tui/lib/allbert_tui/adapter.ex",
    "web" => "apps/allbert_assist_web/lib/allbert_assist_web/live/workspace_live.ex",
    "telegram" => "apps/allbert_telegram/lib/allbert_telegram/adapter.ex",
    "email" => "apps/allbert_email/lib/allbert_email/adapter.ex",
    "discord" => "apps/allbert_discord/lib/allbert_discord/adapter.ex",
    "slack" => "apps/allbert_slack/lib/allbert_slack/adapter.ex",
    "matrix" => "apps/allbert_matrix/lib/allbert_matrix/adapter.ex",
    "whatsapp" => "apps/allbert_whatsapp/lib/allbert_whatsapp/adapter.ex",
    "signal" => "apps/allbert_signal/lib/allbert_signal/adapter.ex",
    "cli" => "apps/allbert_assist/lib/allbert_assist/cli/ask.ex",
    "mix ask" => "apps/allbert_assist/lib/mix/tasks/allbert.ask.ex",
    "jobs" => "apps/allbert_assist/lib/allbert_assist/jobs/runner.ex",
    "ACP" => "apps/allbert_assist/lib/allbert_assist/public_protocol/acp/server.ex",
    "OpenAI" =>
      "apps/allbert_assist_web/lib/allbert_assist_web/controllers/public_protocol/openai_controller.ex"
  }

  @capability_sources Map.merge(@callers, %{
                        "ACP" =>
                          "apps/allbert_assist/lib/allbert_assist/public_protocol/acp/mapping.ex",
                        "OpenAI" =>
                          "apps/allbert_assist/lib/allbert_assist/public_protocol/openai/mapping.ex"
                      })

  @acknowledgement_markers Map.put(
                             Map.new(@callers, fn {surface, _path} ->
                               {surface, ["Runtime.acknowledge_deliveries"]}
                             end),
                             "ACP",
                             [
                               "Runtime.acknowledge_kickoff_delivery",
                               "Runtime.acknowledge_report_delivery"
                             ]
                           )

  test "every production Runtime caller acknowledges only at its delivery boundary" do
    for {surface, relative_path} <- @callers do
      source = File.read!(Path.join(@root, relative_path))

      assert source =~ "Runtime.submit_user_input", "#{surface} no longer calls Runtime"

      for marker <- Map.fetch!(@acknowledgement_markers, surface) do
        assert source =~ marker,
               "#{surface} lost the delivery acknowledgement boundary #{marker}"
      end
    end
  end

  test "remote transports, TUI, and Jobs persist blocked state on delivery failure" do
    for surface <- ~w[tui telegram email discord slack matrix whatsapp signal jobs] do
      source = File.read!(Path.join(@root, Map.fetch!(@callers, surface)))

      assert source =~ "Runtime.track_delivery",
             "#{surface} lost failed-delivery tracking"
    end
  end

  test "every acknowledged caller family declares the closed fan-out capability" do
    for {surface, relative_path} <- @capability_sources do
      source = File.read!(Path.join(@root, relative_path))

      assert source =~ "Runtime.fanout_delivery_ack_capability()",
             "#{surface} acknowledges delivery but does not declare the closed capability"
    end

    # Counted across three files since v1.4 M12, not one. The telegram and email
    # simulate routes moved to their packs, so the residual channels area holds
    # one of these three declarations and each pack CLI holds another. The total
    # is what the invariant is about -- every simulation path declares the closed
    # capability -- so it stays 3 rather than being lowered to match one file.
    simulations =
      [
        "apps/allbert_assist/lib/allbert_assist/cli/areas/channels.ex",
        "apps/allbert_telegram/lib/allbert_telegram/cli.ex",
        "apps/allbert_email/lib/allbert_email/cli.ex"
      ]
      |> Enum.map_join("\n", &File.read!(Path.join(@root, &1)))

    assert length(Regex.scan(~r/delivery_ack_capability:/, simulations)) == 3
  end
end
