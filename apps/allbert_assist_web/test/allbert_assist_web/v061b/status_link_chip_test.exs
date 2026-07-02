defmodule AllbertAssistWeb.V061b.StatusLinkChipTest do
  @moduledoc """
  v0.61b M2 proof (feedback #5, ADR 0080 §5): the chat-header objective chip is
  a labeled link-chip — its visible label names status + the truncated
  objective title, its accessible name predicts the navigation
  ("View objective <title> — status: <status>"), it carries the link
  affordance class, and three or more active objectives collapse to the two
  most recent chips plus a "+N more" link to `/objectives`.
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Objectives

  @moduletag :status_chip

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "the objective chip names destination, title, and status", %{conn: conn} do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "Ship weekly digest",
               objective: "Produce and send the weekly digest.",
               status: "running"
             })

    {:ok, view, _html} = live(conn, ~p"/workspace")

    chip = element(view, "#objective-badge-#{objective.id}")
    html = render(chip)

    assert html =~ "Running · Ship weekly digest"
    assert html =~ ~s(aria-label="View objective Ship weekly digest — status: running")
    assert html =~ "allbert-chip-link"
    assert html =~ ~s(href="/objectives/#{objective.id}")
  end

  test "long titles truncate in the visible label but not the accessible name", %{conn: conn} do
    long_title = "Analyze the quarterly portfolio rebalancing strategy"

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: long_title,
               objective: "Long-running analysis objective.",
               status: "open"
             })

    {:ok, view, _html} = live(conn, ~p"/workspace")

    html = render(element(view, "#objective-badge-#{objective.id}"))

    assert html =~ "Open · Analyze the quarterly p…"
    assert html =~ ~s(aria-label="View objective #{long_title} — status: open")
  end

  test "three or more active objectives collapse to two chips plus a +N more link", %{
    conn: conn
  } do
    for index <- 1..3 do
      assert {:ok, _objective} =
               Objectives.create_objective(%{
                 user_id: "local",
                 title: "Objective #{index}",
                 objective: "Objective #{index} body.",
                 status: "open"
               })
    end

    {:ok, view, _html} = live(conn, ~p"/workspace")

    html = render(element(view, "#objective-badges"))
    chip_count = length(String.split(html, "objective-badge-")) - 1

    assert chip_count == 2
    assert has_element?(view, "#objective-badges-overflow", "+1 more")
    assert render(element(view, "#objective-badges-overflow")) =~ ~s(href="/objectives")

    IO.puts(
      "status-chip-link-labeling-001 status=pass label=status+title overflow=+N_more " <>
        "aria=view_objective authority=none"
    )
  end

  test "the link-chip affordance is tokenized in the stylesheet" do
    css = File.read!(@css_path)

    assert css =~ ".allbert-chip-link:hover span {"
    assert css =~ ".allbert-chip-link {"

    [affordance] =
      Regex.run(~r/\.allbert-chip-link\s*\{(.*?)\n\}/s, css, capture: :all_but_first)

    assert affordance =~ "cursor: pointer;"
  end
end
