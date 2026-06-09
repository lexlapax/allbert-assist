defmodule AllbertAssist.PublicProtocol.RateLimiterTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  import ExUnit.CaptureLog

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

  test "rate limiter fails closed when the supervised process is unavailable" do
    rate_limit = %{limit: 10, period_ms: 1000, burst: 0}
    handler_id = "rate-limiter-fallback-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:allbert, :public_protocol, :rate_limiter, :fallback],
        fn event, measurements, metadata, _config ->
          send(parent, {:rate_limiter_fallback, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :rate_limited} =
                 RateLimiter.check("mcp_http", "claude", rate_limit,
                   now_ms: 0,
                   name: :missing_public_protocol_limiter
                 )
      end)

    assert log =~ "public protocol rate limiter unavailable"
    assert log =~ "surface=\"mcp_http\""
    assert log =~ "client_id=\"claude\""
    assert log =~ "reason=:unavailable"

    assert_received {:rate_limiter_fallback,
                     [:allbert, :public_protocol, :rate_limiter, :fallback], %{count: 1},
                     %{surface: "mcp_http", client_id: "claude", reason: :unavailable}}
  end
end
