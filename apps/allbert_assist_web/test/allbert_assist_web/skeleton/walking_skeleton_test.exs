defmodule AllbertAssistWeb.Skeleton.WalkingSkeletonTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssistWeb.Skeleton.RouteManifest

  @moduletag :v060_walking_skeleton

  test "route manifest mirrors the M2 IA preview-route manifest" do
    assert RouteManifest.known_catalog_components?()
    assert RouteManifest.routes() == doc_manifest_rows()
    assert RouteManifest.preview_paths() == Enum.map(doc_manifest_rows(), & &1.preview_path)
  end

  test "every preview route resolves through the operator shell and known catalog placeholders",
       %{
         conn: conn
       } do
    for route <- RouteManifest.routes() do
      {:ok, view, html} = live(conn, route.preview_path)

      assert html =~ ~s(data-skeleton-preview="v060")
      assert html =~ ~s(data-skeleton-live-data="false")
      assert html =~ ~s(data-authority="none")
      assert html =~ ~s(data-settings-keys="0")
      assert html =~ ~s(data-focus-trap-ready="true")
      assert html =~ ~s(data-high-contrast-ready="true")
      assert html =~ ~s(data-reduced-motion-ready="true")

      assert has_element?(view, "#v060-preview-shell[data-active-page='#{route.active_key}']")

      assert has_element?(
               view,
               "a[aria-current='page'][href='#{route.preview_path}']",
               route.title
             )

      assert has_element?(view, "#v060-preview-#{route.route_id}")
      assert has_element?(view, "#v060-preview-surface-#{route.route_id}")
      assert has_element?(view, "[data-workspace-component='empty_state']")
      assert has_element?(view, "[data-workspace-component='status_badge']")

      for nav_item <- RouteManifest.nav_items() do
        assert has_element?(view, "a[href='#{nav_item.path}']", nav_item.label)
      end

      for component <- route.catalog_components do
        assert has_element?(view, "[data-skeleton-catalog-component='#{component}']")
      end

      refute html =~ "data-placeholder-component"
      refute html =~ "unknown workspace component"
      refute html =~ "Approve"
      refute html =~ "Promote"
      refute html =~ "Send"
    end

    IO.puts(
      "walking-skeleton-routes-resolve-001 status=pass route_count=#{length(RouteManifest.routes())}"
    )

    IO.puts(
      "walking-skeleton-nav-shell-001 status=pass active_route=true nav_items=#{length(RouteManifest.nav_items())}"
    )

    IO.puts(
      "walking-skeleton-a11y-smoke-001 status=pass focus_trap=true high_contrast=true reduced_motion=true"
    )

    IO.puts(
      "no-new-authority-design-only-001 status=pass live_data=false authority=none settings_keys=0"
    )
  end

  test "preview routes do not displace live routes", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    refute html =~ ~s(data-skeleton-preview="v060")
    assert html =~ ~s(data-workspace-shell="operator")
  end

  defp doc_manifest_rows do
    doc_path()
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(
      &(&1 != "| route_id | preview_path | title | nav_group | active_key | catalog_components |")
    )
    |> Enum.drop(2)
    |> Enum.take_while(&String.starts_with?(&1, "| "))
    |> Enum.map(&parse_doc_manifest_row/1)
  end

  defp parse_doc_manifest_row(row) do
    [route_id, preview_path, title, nav_group, active_key, catalog_components] =
      row
      |> String.trim()
      |> String.trim_leading("|")
      |> String.trim_trailing("|")
      |> String.split("|")
      |> Enum.map(&String.trim/1)

    %{
      route_id: String.to_existing_atom(route_id),
      preview_path: preview_path,
      title: title,
      nav_group: nav_group,
      active_key: active_key,
      catalog_components:
        catalog_components
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.to_existing_atom/1)
    }
  end

  defp doc_path do
    Path.expand("../../../../../docs/design/information-architecture.md", __DIR__)
  end
end
