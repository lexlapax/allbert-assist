defmodule AllbertAssist.Surfaces.ContextBuilderTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Surfaces.ContextBuilder

  test "builds CLI context with actor and request metadata" do
    context =
      ContextBuilder.cli_context(
        user_id: "operator",
        session_id: "sess-1",
        surface: "mix allbert.settings"
      )

    assert context.actor == "operator"
    assert context.user_id == "operator"
    assert context.operator_id == "operator"
    assert context.channel == :cli
    assert context.session_id == "sess-1"
    assert context.request.user_id == "operator"
    assert context.request.source == "mix allbert.settings"
  end

  test "builds LiveView context from socket assigns" do
    socket = %{
      id: "phx-1",
      assigns: %{
        user_id: "web-user",
        session_id: "web-session",
        thread_id: "thr-1",
        active_app: :allbert,
        canvas_destination: "drafts"
      }
    }

    context =
      ContextBuilder.live_view_context(socket,
        surface: "AllbertAssistWeb.WorkspaceLive"
      )

    assert context.actor == "web-user"
    assert context.user_id == "web-user"
    assert context.session_id == "web-session"
    assert context.thread_id == "thr-1"
    assert context.canvas_destination == "drafts"
    assert context.response_target == "phx-1"
    assert context.request.channel == :live_view
    assert context.request.session_id == "web-session"
  end

  test "builds public protocol context with client identity" do
    context = ContextBuilder.public_protocol_context("mcp_stdio", "claude")

    assert context.actor == "public-protocol:claude"
    assert context.user_id == "public-protocol:claude"
    assert context.channel == :mcp_stdio
    assert context.surface == "mcp_stdio"
    assert context.public_protocol == %{surface: "mcp_stdio", client_id: "claude"}
    assert context.request.operator_id == "public-protocol:claude"
    assert context.request.channel == :mcp_stdio
  end

  test "builds channel callback context with resolver metadata" do
    context =
      ContextBuilder.channel_context("telegram", "local-user",
        session_id: "chan-session",
        resolver_metadata: %{"callback_query_id" => "cb-1"}
      )

    assert context.actor == "local-user"
    assert context.channel == "telegram"
    assert context.surface == "telegram_callback"
    assert context.session_id == "chan-session"
    assert context.resolver_metadata == %{"callback_query_id" => "cb-1"}
    assert context.request.user_id == "local-user"
    assert context.request.source == "telegram_callback"
  end
end
