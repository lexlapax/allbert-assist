defmodule AllbertAssistWeb.SearchLiveTest do
  use AllbertAssistWeb.ConnCase, async: false
  use AllbertAssistWeb.WorkspaceLiveCase

  import Phoenix.LiveViewTest

  alias AllbertAssist.Conversations
  alias AllbertAssist.Search.Projection

  @moduletag :liveview_serial

  setup %{root: root} do
    start_supervised!({Projection, root: Path.join(root, "search-projection"), name: Projection})
    :ok
  end

  test "workspace dispatches explicit Search through Runtime and renders source identity", %{
    conn: conn
  } do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Web Search")

    assert {:ok, source} =
             Conversations.append_user_message(thread, "web surface search fixture",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, _build} = Projection.rebuild("local")
    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "/search web surface"})

    html = render_async(view, 5_000)

    assert html =~ "Search results: 1"
    assert html =~ "operator · tui"
    assert html =~ "conversation:#{source.id} thread:#{thread.id}"
    refute_received {:runtime_request, _request}
  end
end
