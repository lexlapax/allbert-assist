defmodule AllbertAssistWeb.WorkspaceCanvasTilesTest do
  use AllbertAssistWeb.ConnCase, async: false
  use AllbertAssistWeb.WorkspaceLiveCase

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Settings, Workspace}
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Fragment.Body, as: FragmentBody
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias AllbertAssistWeb.SignalBridge

  test "renders emitted canvas fragments through the workspace shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    envelope =
      signed_envelope(%{
        thread_id: thread_id,
        surface: fragment_surface(:text, "Canvas fragment body")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    html = render_until(view, "Canvas fragment body")

    assert has_element?(view, "#workspace-node-canvas-tile-#{envelope.id}")
    assert html =~ "Canvas fragment body"

    assert {:ok, [tile]} = Workspace.canvas_tiles(thread_id, "local")
    assert tile.id == envelope.id
  end

  test "renders emitted ephemeral fragments through the workspace shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    envelope =
      signed_envelope(%{
        thread_id: thread_id,
        scope: :ephemeral,
        kind: :approval_card,
        surface: fragment_surface(:approval_card, "Approval fragment body")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    html = render_until(view, "Approval fragment body")

    assert has_element?(view, "#workspace-node-ephemeral-surface-#{envelope.id}")
    assert html =~ "Approval fragment body"

    assert {:ok, [surface]} = Workspace.ephemeral_surfaces(thread_id, "local")
    assert surface.id == envelope.id
  end

  test "workspace ephemeral dismissal routes Escape through the action boundary", %{conn: conn} do
    thread = create_workspace_thread()

    envelope =
      signed_envelope(%{
        thread_id: thread.id,
        scope: :ephemeral,
        kind: :approval_card,
        surface: fragment_surface(:approval_card, "Dismiss me")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    assert has_element?(view, "#workspace-node-ephemeral-surface-#{envelope.id}")

    assert has_element?(
             view,
             "#workspace-node-ephemeral-surface-#{envelope.id}[phx-key='escape']"
           )

    subscribe_actions()

    view
    |> element("#workspace-node-ephemeral-surface-#{envelope.id}")
    |> render_keydown(%{"key" => "Escape"})

    action_signal = receive_action_completed("dismiss_workspace_ephemeral")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :workspace_canvas_write
    assert {:ok, []} = Workspace.ephemeral_surfaces(thread.id, "local")
  end

  test "canvas tile controls route through the workspace action boundary", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :text,
               body: %{text: "operator tile controls"}
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    subscribe_actions()

    assert has_element?(view, "#workspace-tile-action-#{tile.id}:not([disabled])")
    assert has_element?(view, "#workspace-tile-menu-button-#{tile.id}:not([disabled])")
    assert has_element?(view, "#workspace-tile-action-#{tile.id}[phx-disable-with]")

    assert has_element?(
             view,
             "#workspace-tile-menu-button-#{tile.id}[aria-haspopup='menu'][aria-expanded='false']"
           )

    view
    |> element("#workspace-tile-action-#{tile.id}")
    |> render_click()

    action_signal = receive_action_completed("manage_workspace_tile")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :workspace_canvas_write
    assert {:ok, pinned} = Workspace.get_tile(tile.id, "local")
    assert pinned.pinned == true

    menu_html =
      view
      |> element("#workspace-tile-menu-button-#{tile.id}")
      |> render_click()

    assert menu_html =~ "Remove tile"

    assert has_element?(
             view,
             "#workspace-tile-menu-button-#{tile.id}[aria-haspopup='menu'][aria-expanded='true']"
           )

    view
    |> element("#workspace-tile-menu-#{tile.id} [phx-value-operation='remove']")
    |> render_click()

    remove_signal = receive_action_completed("manage_workspace_tile")
    assert remove_signal.data.status == :completed
    assert [remove_action] = remove_signal.data.response.actions
    assert remove_action.workspace_metadata.operation == :remove
    assert {:ok, []} = Workspace.canvas_tiles(thread.id, "local")
    assert {:ok, [deleted]} = Workspace.canvas_tiles(thread.id, "local", include_deleted: true)
    refute is_nil(deleted.deleted_at)
  end

  test "tile inspector opens from the tile menu and closes by Escape or button", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :text,
               body: %{text: "operator tile inspector body"},
               metadata: %{"emitter_id" => "AllbertAssist.TestEmitter"}
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    menu_html =
      view
      |> element("#workspace-tile-menu-button-#{tile.id}")
      |> render_click()

    assert menu_html =~ "Inspect"

    assert has_element?(
             view,
             "#workspace-tile-inspect-#{tile.id}[phx-click='open_tile_inspector']"
           )

    inspector_html =
      view
      |> element("#workspace-tile-inspect-#{tile.id}")
      |> render_click()

    assert inspector_html =~ "Tile inspector"
    assert inspector_html =~ "operator tile inspector body"
    assert inspector_html =~ "AllbertAssist.TestEmitter"
    assert has_element?(view, "#workspace-tile-inspector[role='dialog'][phx-hook='FocusTrap']")
    assert has_element?(view, "#workspace-tile-inspector-copy-id[data-copy-value='#{tile.id}']")
    assert has_element?(view, "#workspace-tile-inspector-copy-body")
    refute has_element?(view, "#workspace-tile-menu-#{tile.id}")

    view
    |> element("#workspace-tile-inspector")
    |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#workspace-tile-inspector")

    view
    |> element("#workspace-tile-menu-button-#{tile.id}")
    |> render_click()

    view
    |> element("#workspace-tile-inspect-#{tile.id}")
    |> render_click()

    view
    |> element("#workspace-tile-inspector-close")
    |> render_click()

    refute has_element?(view, "#workspace-tile-inspector")
  end

  @tag timeout: 180_000
  test "ephemeral lifecycle events fan out open and close to sibling tabs", %{conn: conn} do
    start_workspace_sync()
    thread = create_workspace_thread()

    {:ok, first_tab, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    {:ok, second_tab, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    envelope =
      signed_envelope(%{
        thread_id: thread.id,
        scope: :ephemeral,
        kind: :approval_card,
        surface: fragment_surface(:approval_card, "Synced approval")
      })

    assert {:ok, surface} =
             Workspace.open_ephemeral(%{
               id: envelope.id,
               user_id: "local",
               thread_id: thread.id,
               kind: :approval_card,
               body: FragmentBody.encode(envelope)
             })

    render_until(first_tab, "ephemeral-surface-#{surface.id}")
    render_until(second_tab, "ephemeral-surface-#{surface.id}")
    subscribe_actions()

    render_hook(first_tab, :dismiss_workspace_ephemeral, %{"surface-id" => surface.id})

    action_signal = receive_action_completed("dismiss_workspace_ephemeral")
    assert action_signal.data.status == :completed

    render_until_missing(first_tab, "#workspace-node-ephemeral-surface-#{surface.id}")
    render_until_missing(second_tab, "#workspace-node-ephemeral-surface-#{surface.id}")
  end

  test "renders canvas-header badge fragments without persisting them as tiles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    envelope =
      signed_envelope(%{
        thread_id: thread_id,
        emitter_id: "AllbertAssist.Workspace.Canvas",
        kind: :badge_strip,
        metadata: %{placement: "canvas_header"},
        surface: fragment_surface(:status_badge, "1 older tile(s) archived")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    html = render_until(view, "1 older tile(s) archived")

    assert has_element?(view, "#workspace-header-badge-#{envelope.id}")
    assert html =~ "1 older tile(s) archived"
    assert {:ok, []} = Workspace.canvas_tiles(thread_id, "local")
  end

  test "ignores fragments for a different thread", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    envelope =
      signed_envelope(%{
        thread_id: "thr_other_thread",
        surface: fragment_surface(:text, "Wrong thread body")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    html = render(view)

    refute html =~ "Wrong thread body"
    assert {:ok, []} = Workspace.canvas_tiles(thread_id, "local")
  end

  test "workspace tile mutations fan out to a second tab", %{conn: conn} do
    start_workspace_sync()

    {:ok, first_tab, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(first_tab)
    {:ok, second_tab, _html} = live(conn, ~p"/workspace?thread_id=#{thread_id}")

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread_id,
               kind: :text,
               body: %{text: "two-tab sync tile"}
             })

    html = render_until(second_tab, tile.id)

    assert html =~ "canvas-tile-#{tile.id}"
  end

  @tag timeout: 180_000
  test "workspace tile mutations fan out to three tabs", %{conn: conn} do
    start_workspace_sync()

    {:ok, first_tab, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(first_tab)

    tabs =
      [first_tab] ++
        for _index <- 1..2 do
          assert {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread_id}")
          view
        end

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread_id,
               kind: :text,
               body: %{text: "three-tab sync tile"}
             })

    for view <- tabs do
      html = render_until(view, tile.id)
      assert html =~ "canvas-tile-#{tile.id}"
    end
  end

  test "renders editable text tiles with a Yjs-backed editor hook", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :text,
               body: %{text: "offline draft body"}
             })

    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    subscribe_actions()

    assert has_element?(
             view,
             "#workspace-tile-editor-#{tile.id}[phx-hook='WorkspaceTileEditor'][phx-update='ignore'][data-tile-id='#{tile.id}'][data-thread-id='#{thread.id}'][data-user-id='local'][data-quota-bytes='33554432']"
           )

    assert html =~ "offline draft body"

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "thread_id" => thread.id,
      "user_id" => "local",
      "kind" => "text",
      "update" => "AQID",
      "state_vector" => "BAUG",
      "snapshot" => "offline draft body"
    })

    tile_id = tile.id
    action_signal = receive_action_completed("record_workspace_offline_update")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :workspace_canvas_write

    assert_reply(view, %{
      status: "received",
      tile_id: ^tile_id,
      revision_id: revision_id,
      current_revision_id: revision_id,
      conflict_count: 0,
      max_bytes: 33_554_432
    })

    assert render_until(view, revision_id) =~ "data-base-revision-id=\"#{revision_id}\""
  end

  test "workspace tile editor hook respects workspace write denial", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :text,
               body: %{text: "permission base"}
             })

    assert {:ok, _setting} =
             Settings.put("permissions.workspace_canvas_write", "denied", %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "thread_id" => thread.id,
      "snapshot" => "blocked edit"
    })

    assert_reply(view, %{status: "rejected", reason: ":permission_denied"})
    assert {:ok, "permission base"} = Workspace.latest_offline_snapshot(tile.id, "local")
  end

  test "workspace tile editor hook reports stale-base conflicts", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :text,
               body: %{text: "conflict base"}
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "thread_id" => thread.id,
      "user_id" => "local",
      "kind" => "text",
      "snapshot" => "first synced edit"
    })

    tile_id = tile.id

    assert_reply(view, %{
      status: "received",
      tile_id: ^tile_id,
      current_revision_id: first_revision_id,
      conflict_count: 0
    })

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "thread_id" => thread.id,
      "user_id" => "local",
      "kind" => "text",
      "base_revision_id" => nil,
      "origin" => "offline_reconnect",
      "snapshot" => "stale offline edit"
    })

    assert_reply(view, %{
      status: "conflict",
      tile_id: ^tile_id,
      current_revision_id: current_revision_id,
      conflict_count: 1
    })

    assert current_revision_id != first_revision_id

    html = render_until(view, "Conflict reconciled.")
    assert html =~ "1 offline edit(s) were merged"
    assert html =~ "revert_tile_revision"
  end

  test "workspace tile editor hook rejects non-editable tiles", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :analysis_card,
               body: %{text: "read-only analysis"}
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    refute has_element?(view, "#workspace-tile-editor-#{tile.id}")

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "update" => "AQID",
      "state_vector" => "BAUG",
      "snapshot" => "read-only analysis"
    })

    assert_reply(view, %{status: "rejected", reason: ":unsupported_tile_kind"})
  end

  test "renders durable StockSage canvas tiles with real card renderers", %{conn: conn} do
    ensure_stocksage_app_registered()
    thread = create_workspace_thread("StockSage canvas thread")

    envelope =
      signed_envelope(%{
        id: "stocksage_analysis_ana_live_canvas",
        user_id: "local",
        thread_id: thread.id,
        emitter_id: "StockSage.Actions.RunAnalysis",
        scope: :canvas,
        kind: :analysis_card,
        surface: stocksage_analysis_surface("ana_live_canvas")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=#{thread.id}&app_id=stocksage")

    assert has_element?(view, ~s([data-stocksage-component="analysis_card"]))
    assert has_element?(view, "#workspace-tile-menu-button-stocksage_analysis_ana_live_canvas")
    assert html =~ "AAPL analysis completed"
    assert html =~ "Constructive setup."
    refute html =~ "v0.26 stub"
    refute html =~ "workspace-card-stub"
  end

  # The LiveView fan-out sync process (`AllbertAssistWeb.SignalBridge`) is an
  # owned, uniquely named, test-supervised process — not a shared OS resource.
  defp start_workspace_sync do
    name = :"workspace_live_signal_sync_#{System.unique_integer([:positive])}"
    start_supervised!({SignalBridge, name: name})
  end

  defp signed_envelope(attrs) do
    secret = SigningSecret.ensure!()

    attrs =
      Map.merge(
        %{
          surface: fragment_surface(:text, "Fragment body"),
          emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer",
          user_id: "local",
          thread_id: "thr_test_default",
          scope: :canvas,
          kind: :text,
          emitted_at: ~U[2026-05-18 00:00:00Z]
        },
        attrs
      )

    assert {:ok, envelope} = Envelope.sign(attrs, secret)
    envelope
  end

  defp fragment_surface(component, body) do
    %Surface{
      id: :fragment,
      app_id: :allbert,
      label: "Fragment",
      path: "/workspace",
      kind: :canvas,
      status: :available,
      nodes: [
        %Node{
          id: "fragment-#{component}",
          component: component,
          props: %{title: "Fragment", body: body}
        }
      ],
      fallback_text: "Fragment fallback"
    }
  end

  defp stocksage_analysis_surface(analysis_id) do
    %Surface{
      id: :stocksage_analysis_card,
      app_id: :stocksage,
      label: "StockSage Analysis",
      path: "/apps/stocksage/analyses/#{analysis_id}",
      kind: :analysis,
      status: :available,
      nodes: [
        %Node{
          id: "analysis-#{analysis_id}",
          component: :analysis_card,
          props: %{
            title: "AAPL analysis completed",
            analysis_id: analysis_id,
            ticker: "AAPL",
            symbol: "AAPL",
            analysis_date: "2026-05-18",
            engine: "native",
            status: "completed",
            rating: "Overweight",
            recommendation: "Overweight",
            confidence: 0.82,
            summary: "Constructive setup.",
            route: "/apps/stocksage/analyses/#{analysis_id}"
          }
        }
      ],
      fallback_text: "AAPL analysis completed",
      metadata: %{source: "stocksage", fragment_id: "stocksage_analysis_#{analysis_id}"}
    }
  end
end
