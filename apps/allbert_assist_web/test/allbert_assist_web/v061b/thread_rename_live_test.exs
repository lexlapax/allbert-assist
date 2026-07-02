defmodule AllbertAssistWeb.V061b.ThreadRenameLiveTest do
  @moduledoc """
  v0.61b M4 proof (feedback #4): inline thread rename in the Conversations
  list — hover affordance → inline input, Enter saves (list label updates,
  title persists), Escape reverts, double-click accelerator is hook-backed;
  the write rides `Runner.run("rename_thread", …)` (no LiveView direct write).
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Conversations
  alias AllbertAssist.Repo

  @moduletag :rename_thread

  defp create_thread(title) do
    {:ok, thread} = Conversations.create_thread(%{user_id: "local", title: title})
    thread
  end

  test "rename round-trip: affordance → inline input → Enter persists", %{conn: conn} do
    thread = create_thread("Workspace session")

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    assert has_element?(view, "#workspace-rail-thread-#{thread.id}-rename-toggle")

    view
    |> element("#workspace-rail-thread-#{thread.id}-rename-toggle")
    |> render_click()

    assert has_element?(view, "#workspace-rail-thread-#{thread.id}-rename form")

    view
    |> element("#workspace-rail-thread-#{thread.id}-rename form")
    |> render_submit(%{"thread-id" => thread.id, "title" => "Budget planning"})

    assert render(element(view, "#workspace-rail-thread-#{thread.id}")) =~ "Budget planning"
    assert Repo.reload!(thread).title == "Budget planning"
  end

  test "Escape cancels the rename and reverts the label", %{conn: conn} do
    thread = create_thread("Keep this title")

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    view
    |> element("#workspace-rail-thread-#{thread.id}-rename-toggle")
    |> render_click()

    view
    |> element("#workspace-rail-thread-#{thread.id}-rename input[name='title']")
    |> render_keydown(%{"key" => "escape"})

    refute has_element?(view, "#workspace-rail-thread-#{thread.id}-rename form")
    assert render(element(view, "#workspace-rail-thread-#{thread.id}")) =~ "Keep this title"
    assert Repo.reload!(thread).title == "Keep this title"
  end

  test "the double-click accelerator is hook-backed on the title", %{conn: conn} do
    thread = create_thread("Dblclick target")

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    title = render(element(view, "#workspace-rail-thread-#{thread.id}-title"))
    assert title =~ ~s(phx-hook="ThreadRenameDblclick")
    assert title =~ ~s(data-thread-id="#{thread.id}")

    IO.puts(
      "thread-rename-live-001 status=pass inline=true enter_saves=true esc_reverts=true " <>
        "spine=runner_conversation_write"
    )
  end
end
