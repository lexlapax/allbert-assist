defmodule AllbertAssist.Runtime.FanoutCallersTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  @root Path.expand("../../../../..", __DIR__)

  @callers %{
    "tui" => "plugins/allbert.tui/lib/allbert_assist/channels/tui/adapter.ex",
    "web" => "apps/allbert_assist_web/lib/allbert_assist_web/live/workspace_live.ex",
    "telegram" => "plugins/allbert.telegram/lib/allbert_assist/channels/telegram/adapter.ex",
    "email" => "plugins/allbert.email/lib/allbert_assist/channels/email/adapter.ex",
    "discord" => "plugins/allbert.discord/lib/allbert_assist/channels/discord/adapter.ex",
    "slack" => "plugins/allbert.slack/lib/allbert_assist/channels/slack/adapter.ex",
    "matrix" => "plugins/allbert.matrix/lib/allbert_assist/channels/matrix/adapter.ex",
    "whatsapp" => "plugins/allbert.whatsapp/lib/allbert_assist/channels/whatsapp/adapter.ex",
    "signal" => "plugins/allbert.signal/lib/allbert_assist/channels/signal/adapter.ex",
    "cli" => "apps/allbert_assist/lib/allbert_assist/cli/ask.ex",
    "mix ask" => "apps/allbert_assist/lib/mix/tasks/allbert.ask.ex",
    "jobs" => "apps/allbert_assist/lib/allbert_assist/jobs/runner.ex",
    "ACP" => "apps/allbert_assist/lib/allbert_assist/public_protocol/acp/server.ex",
    "OpenAI" =>
      "apps/allbert_assist_web/lib/allbert_assist_web/controllers/public_protocol/openai_controller.ex"
  }

  test "every production Runtime caller acknowledges only at its delivery boundary" do
    for {surface, relative_path} <- @callers do
      source = File.read!(Path.join(@root, relative_path))

      assert source =~ "Runtime.submit_user_input", "#{surface} no longer calls Runtime"

      assert source =~ "Runtime.acknowledge_deliveries",
             "#{surface} lost the kickoff/report delivery acknowledgement"
    end
  end

  test "remote transports, TUI, and Jobs persist blocked state on delivery failure" do
    for surface <- ~w[tui telegram email discord slack matrix whatsapp signal jobs] do
      source = File.read!(Path.join(@root, Map.fetch!(@callers, surface)))

      assert source =~ "Runtime.track_delivery",
             "#{surface} lost failed-delivery tracking"
    end
  end
end
