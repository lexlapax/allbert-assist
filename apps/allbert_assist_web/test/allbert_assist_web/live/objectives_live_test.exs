defmodule AllbertAssistWeb.ObjectivesLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Objectives
  alias AllbertAssist.Surface.Catalog

  test "renders a populated objectives index through the catalog renderer", %{conn: conn} do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               status: "running",
               active_app: "stocksage",
               source_thread_id: "thread_objectives_index"
             })

    assert {:ok, _other_user} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Alice only",
               objective: "Should not leak."
             })

    {:ok, view, html} = live(conn, ~p"/objectives")

    assert has_element?(view, "#operator-shell[data-active-page='objectives']")
    assert has_element?(view, "#objectives-catalog-renderer[data-workspace-renderer='surface']")

    assert has_element?(
             view,
             "#objective-index-#{objective.id}[data-workspace-component='objective_card']"
           )

    assert has_element?(
             view,
             "#objective-open-#{objective.id}[href='/objectives/#{objective.id}']"
           )

    assert html =~ "Analyze AAPL"
    assert html =~ "running"
    assert html =~ objective.id
    refute html =~ "Alice only"
    assert_catalog_components_known!(html)
  end

  test "the ?user= param is ignored — no cross-user objective disclosure (IDOR guard)", %{
    conn: conn
  } do
    assert {:ok, _local} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "Local objective",
               objective: "Local operator work.",
               status: "running"
             })

    assert {:ok, _alice} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Alice private objective",
               objective: "Must never leak via a URL param."
             })

    # Attempt the pre-M10.2 IDOR: request another user's objectives via the URL param.
    {:ok, _view, html} = live(conn, ~p"/objectives?#{[user: "alice"]}")

    # The index reads the server-derived local identity through the registered action;
    # the param is inert — alice's objectives are never disclosed.
    refute html =~ "Alice private objective"
    refute html =~ "Must never leak"
    assert html =~ "Local objective"
  end

  test "renders the first-run empty state through the catalog without authority", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/objectives")

    assert has_element?(view, "#objectives-catalog-renderer[data-workspace-renderer='surface']")

    assert has_element?(
             view,
             "#workspace-component-objectives-empty[data-workspace-component='empty_state']"
           )

    assert has_element?(view, "#objectives-empty-actions a[href='/workspace']")
    assert html =~ "No objectives yet."
    refute html =~ "phx-click=\"create"
    refute html =~ "phx-click=\"continue"
    assert_catalog_components_known!(html)
  end

  defp assert_catalog_components_known!(html) do
    known_components = Catalog.known_components() |> Enum.map(&Atom.to_string/1)

    rendered_components =
      ~r/data-workspace-component="([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert rendered_components != []
    assert Enum.all?(rendered_components, &(&1 in known_components))
  end
end
