defmodule AllbertAssist.Intent.ConversationContextTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.ConversationContext, as: CC

  defp tc(messages), do: %{thread_id: "t", user_id: "u", limit: 12, messages: messages}

  defp msg(role, content),
    do: %{role: role, content: content, inserted_at: "2026-06-16T00:00:00Z", trace_id: nil}

  test "returns empty when multi-turn is disabled" do
    assert CC.from_thread_context(tc([msg("user", "hi")]), multiturn_enabled: false) == CC.empty()
  end

  test "summarizes only the last context_window turns" do
    messages = [
      msg("user", "one"),
      msg("assistant", "two"),
      msg("user", "three"),
      msg("assistant", "four")
    ]

    ctx = CC.from_thread_context(tc(messages), multiturn_enabled: true, context_window: 2)

    assert ctx.turn_count == 2
    assert ctx.summary =~ "user: three"
    assert ctx.summary =~ "assistant: four"
    refute ctx.summary =~ "one"
    refute ctx.summary =~ "two"
  end

  test "redacts secrets in the summary (no raw history reaches the prompt)" do
    ctx =
      tc([msg("user", "my key is sk-abc123def456ghi789xyz ok")])
      |> CC.from_thread_context(multiturn_enabled: true, context_window: 6)

    assert ctx.summary =~ "[REDACTED]"
    refute ctx.summary =~ "sk-abc123def456ghi789xyz"
  end

  test "bounds long content" do
    ctx =
      tc([msg("user", String.duplicate("x", 500))])
      |> CC.from_thread_context(multiturn_enabled: true, context_window: 6)

    assert String.length(ctx.summary) <= 200
  end

  test "carries antecedent signals when supplied" do
    ctx =
      tc([msg("user", "what about NVDA")])
      |> CC.from_thread_context(
        multiturn_enabled: true,
        context_window: 6,
        prior_app: "stocksage",
        prior_action: "quote"
      )

    assert ctx.prior_app == "stocksage"
    assert ctx.prior_action == "quote"
  end
end
