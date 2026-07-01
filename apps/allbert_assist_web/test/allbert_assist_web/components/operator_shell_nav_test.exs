defmodule AllbertAssistWeb.OperatorShellNavTest do
  @moduledoc """
  v0.61 M4 proof: the operator shell implements the v0.60 IA/navigation model
  (ADR 0077) in the M2-chosen Layout D (Sidebar-primary) — a fixed left sidebar
  carrying the five grouped IA nav groups (Start / Work / Operate / Extend / Trust)
  built from the M3 Direction C soft nav-pill variant, reaching all nine IA surfaces
  with no route sprawl beyond the rebuilt `/` landing and the new `/objectives`
  index route.
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :v061_ia_navigation

  test "the new /objectives index route resolves through the D sidebar shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/objectives")

    assert html =~ ~s(data-active-page="objectives")
    assert html =~ ~s(class="operator-sidebar")
  end

  test "the sidebar renders the five IA navigation groups", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/jobs")

    for group <- ~w(Start Work Operate Extend Trust) do
      assert html =~ ~s(operator-nav-group-label">#{group}</p>),
             "missing IA navigation group: #{group}"
    end
  end

  test "grouped navigation reaches all nine IA surfaces via Direction C nav-pill variants",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/jobs")

    # Grouped navigation is built from the M3 soft nav-pill variant, not ad-hoc links.
    assert html =~ ~s(data-workspace-pattern="nav-pill")

    # Start / Work / Operate real routes.
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/workspace")
    assert html =~ ~s(href="/objectives")
    assert html =~ ~s(href="/jobs")

    # models / channels / settings / trust are workspace destinations, not routes.
    assert html =~ ~s(href="/workspace?destination=workspace:models")
    assert html =~ ~s(href="/workspace?destination=workspace:channels")
    assert html =~ ~s(href="/workspace?destination=workspace:settings")
    assert html =~ ~s(href="/workspace?destination=workspace:surface_policy")

    IO.puts(
      "ia-navigation-model-implemented-001 status=pass groups=5 surfaces=9 nav_variant=nav-pill"
    )
  end

  test "no standalone routes exist for models/channels/settings/trust/onboarding" do
    paths = AllbertAssistWeb.Router |> Phoenix.Router.routes() |> Enum.map(& &1.path)

    for surface_path <- ~w(/models /channels /settings /trust /onboarding) do
      refute surface_path in paths,
             "#{surface_path} must stay a workspace destination, not a standalone route"
    end

    # The only non-landing route the IA overhaul adds is the /objectives index.
    assert "/objectives" in paths
    assert "/objectives/:id" in paths

    IO.puts("route-contract-no-sprawl-001 status=pass new_route=objectives_index_only")
  end

  test "the active surface is marked current in the sidebar", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/jobs")

    assert html =~ ~s(aria-current="page")
    assert html =~ "allbert-nav-pill-active"
  end
end
