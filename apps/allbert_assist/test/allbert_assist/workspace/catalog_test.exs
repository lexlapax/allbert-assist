defmodule AllbertAssist.Workspace.CatalogTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Catalog
  alias AllbertAssist.Workspace.Fragment.Body, as: FragmentBody
  alias AllbertAssist.Workspace.Fragment.Envelope

  test "known components returns the v0.32 workspace allow-list" do
    components = Catalog.known_components()

    assert length(components) == 48
    assert Enum.uniq(components) == components

    assert Enum.all?(
             [
               :route,
               :chat,
               :timeline,
               :composer,
               :status_badge,
               :workspace_shell,
               :nav_rail,
               :thread_list,
               :app_launcher,
               :utility_drawer,
               :workspace_panel,
               :workspace,
               :canvas,
               :tile,
               :ephemeral_surface,
               :approval_card,
               :memory_review_card,
               :analysis_card,
               :debate_round_card
             ],
             &(&1 in components)
           )
  end

  test "workspace tree returns the v0.26 core /workspace surface" do
    surface = Catalog.workspace_tree(user_id: "local", thread_id: "thread-1")

    assert surface.id == :workspace
    assert surface.path == "/workspace"
    assert surface.kind == :workspace
    assert surface.metadata.workspace == %{user_id: "local", thread_id: "thread-1"}

    assert [%Node{component: :workspace_shell, children: children}] = surface.nodes
    assert Enum.any?(children, &match?(%Node{component: :chat}, &1))
    assert Enum.any?(children, &match?(%Node{component: :canvas}, &1))
    assert Enum.any?(children, &match?(%Node{component: :nav_rail}, &1))
    assert Enum.any?(children, &match?(%Node{component: :utility_drawer}, &1))
    assert Enum.any?(children, &match?(%Node{component: :ephemeral_surface}, &1))
  end

  test "workspace tree injects persisted canvas and ephemeral fragment nodes" do
    surface =
      Catalog.workspace_tree(
        user_id: "local",
        thread_id: "thread-1",
        canvas_tiles: [
          %{id: "tile-1", kind: "text", body: fragment_body(:text, "Canvas text")}
        ],
        ephemeral_surfaces: [
          %{
            id: "surface-1",
            kind: "approval_card",
            body: fragment_body(:approval_card, "Approval text")
          }
        ]
      )

    assert [%Node{component: :workspace_shell, children: children}] = surface.nodes

    assert %Node{children: [%Node{component: :tile, children: [canvas_child]}]} =
             Enum.find(children, &(&1.component == :canvas))

    assert canvas_child.component == :text
    assert canvas_child.props.body == "Canvas text"

    assert %Node{children: [%Node{component: :ephemeral_surface, children: [ephemeral_child]}]} =
             Enum.find(children, &(&1.component == :ephemeral_surface))

    assert ephemeral_child.component == :approval_card
    assert ephemeral_child.props.body == "Approval text"
  end

  test "workspace tree injects valid panel surfaces into their host zone" do
    surface =
      Catalog.workspace_tree(
        user_id: "local",
        thread_id: "thread-1",
        panel_surfaces: [panel_surface()]
      )

    assert [%Node{component: :workspace_shell, children: children}] = surface.nodes

    assert %Node{component: :canvas, children: canvas_children} =
             Enum.find(children, &(&1.component == :canvas))

    assert %Node{
             id: "workspace-panel-allbert-fixture_panel-fixture-panel-root",
             component: :panel,
             props: %{zone: :canvas_panels, surface_id: :fixture_panel, app_id: :allbert}
           } = Enum.find(canvas_children, &(&1.props[:surface_id] == :fixture_panel))

    refute Map.has_key?(surface.metadata, :panel_diagnostics)
  end

  test "workspace tree drops invalid panel surfaces with bounded diagnostics" do
    surface =
      Catalog.workspace_tree(
        panel_surfaces: [
          panel_surface(%{zone: :made_up}),
          panel_surface(%{id: :wrong_kind, kind: :route, zone: nil})
        ]
      )

    assert [%Node{component: :workspace_shell, children: children}] = surface.nodes

    assert %Node{component: :canvas, children: canvas_children} =
             Enum.find(children, &(&1.component == :canvas))

    refute Enum.any?(canvas_children, &match?(%Node{component: :panel}, &1))

    assert [%{kind: :unknown_zone}, %{kind: :invalid_panel_surface}] =
             surface.metadata.panel_diagnostics
  end

  defp fragment_body(component, body) do
    FragmentBody.encode(%Envelope{
      id: "frag-catalog",
      surface: %Surface{
        id: :fragment,
        app_id: :allbert,
        label: "Fragment",
        path: "/workspace",
        kind: :canvas,
        status: :available,
        nodes: [
          %Node{id: "fragment-#{component}", component: component, props: %{body: body}}
        ],
        fallback_text: "Fragment fallback"
      },
      emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer",
      user_id: "local",
      thread_id: "thread-1",
      scope: :canvas,
      kind: component,
      emitted_at: ~U[2026-05-18 00:00:00Z],
      signature: "already-validated"
    })
  end

  defp panel_surface(attrs \\ %{}) do
    struct!(
      Surface,
      Map.merge(
        %{
          id: :fixture_panel,
          app_id: :allbert,
          label: "Fixture Panel",
          path: "/workspace",
          kind: :panel,
          zone: :canvas_panels,
          status: :available,
          nodes: [
            %Node{
              id: "fixture-panel-root",
              component: :panel,
              props: %{title: "Fixture panel"},
              children: [%Node{id: "fixture-panel-body", component: :text, props: %{body: "ok"}}]
            }
          ],
          fallback_text: "Fixture panel."
        },
        attrs
      )
    )
  end
end
