defmodule AllbertAssist.PublicProtocol.RateLimiterTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.PublicProtocol.RateLimiter

  setup do
    RateLimiter.reset_for_test()
    :ok
  end

  test "rate limiter denies after bucket capacity before runtime work" do
    rate_limit = %{"limit" => 2, "period_ms" => 1000, "burst" => 0}

    assert :ok = RateLimiter.check("mcp_http", "claude", rate_limit, now_ms: 0)
    assert :ok = RateLimiter.check("mcp_http", "claude", rate_limit, now_ms: 0)

    assert {:error, :rate_limited} =
             RateLimiter.check("mcp_http", "claude", rate_limit, now_ms: 0)

    assert :ok = RateLimiter.check("mcp_http", "claude", rate_limit, now_ms: 1000)
  end

  test "rate limiter buckets are scoped by surface and client" do
    rate_limit = %{limit: 1, period_ms: 1000, burst: 0}

    assert :ok = RateLimiter.check(:mcp_http, "one", rate_limit, now_ms: 0)
    assert {:error, :rate_limited} = RateLimiter.check(:mcp_http, "one", rate_limit, now_ms: 0)
    assert :ok = RateLimiter.check(:mcp_http, "two", rate_limit, now_ms: 0)
    assert :ok = RateLimiter.check(:openai_api, "one", rate_limit, now_ms: 0)
  end
end
