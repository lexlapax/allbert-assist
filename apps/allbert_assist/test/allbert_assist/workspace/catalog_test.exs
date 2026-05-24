defmodule AllbertAssist.Workspace.CatalogTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Catalog
  alias AllbertAssist.Workspace.Fragment.Body, as: FragmentBody
  alias AllbertAssist.Workspace.Fragment.Envelope

  test "known components returns the v0.32 workspace allow-list" do
    components = Catalog.known_components()

    assert length(components) == 49
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
               :settings_panel,
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

  test "workspace tree returns the v0.34 core /workspace surface" do
    surface = Catalog.workspace_tree(user_id: "local", thread_id: "thread-1")

    assert surface.id == :workspace
    assert surface.path == "/workspace"
    assert surface.kind == :workspace
    assert surface.metadata.workspace == %{user_id: "local", thread_id: "thread-1"}

    assert [%Node{component: :workspace_shell, children: children}] = surface.nodes
    assert Enum.any?(children, &match?(%Node{component: :chat}, &1))
    assert Enum.any?(children, &match?(%Node{component: :canvas}, &1))
    assert Enum.any?(children, &match?(%Node{component: :nav_rail}, &1))
    refute Enum.any?(children, &match?(%Node{component: :utility_drawer}, &1))
    refute Enum.any?(children, &match?(%Node{component: :badge_strip}, &1))
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

  test "workspace tree does not render retired CoreApp regions by default" do
    surface = Catalog.workspace_tree(user_id: "local", thread_id: "thread-1")

    assert [%Node{component: :workspace_shell, children: children}] = surface.nodes

    assert %Node{component: :canvas, children: canvas_children} =
             Enum.find(children, &(&1.component == :canvas))

    refute find_node(canvas_children, :objective_card, :core_objectives_panel)
    refute find_node(canvas_children, :job_card, :core_jobs_panel)
    refute find_node(canvas_children, :confirmation_card, :core_confirmations_panel)
    refute find_node(canvas_children, :settings_card, :core_security_panel)
    refute find_node(canvas_children, :settings_panel, :core_settings_panel)
    refute Map.has_key?(surface.metadata, :panel_diagnostics)
  end

  test "workspace tree filters active-app panels by explicit app context" do
    hidden =
      Catalog.workspace_tree(
        active_app: :allbert,
        panel_surfaces: [
          panel_surface(%{
            id: :stocksage_fixture_panel,
            app_id: :stocksage,
            metadata: %{visible_when: :selected_app, order: 10}
          })
        ]
      )

    shown =
      Catalog.workspace_tree(
        active_app: :stocksage,
        panel_surfaces: [
          panel_surface(%{
            id: :stocksage_fixture_panel,
            app_id: :stocksage,
            metadata: %{visible_when: :selected_app, order: 10}
          })
        ]
      )

    refute canvas_panel?(hidden, :stocksage_fixture_panel)
    assert canvas_panel?(shown, :stocksage_fixture_panel)
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

  defp canvas_panel?(%Surface{nodes: [%Node{children: children}]}, surface_id) do
    children
    |> Enum.find(&(&1.component == :canvas))
    |> Map.get(:children, [])
    |> Enum.any?(&(&1.props[:surface_id] == surface_id))
  end

  defp find_node(nodes, component, surface_id) do
    Enum.find_value(nodes, fn
      %Node{props: %{surface_id: ^surface_id}} = node ->
        find_component([node], component)

      %Node{children: children} ->
        find_node(children, component, surface_id)

      _node ->
        nil
    end)
  end

  defp find_component(nodes, component) do
    Enum.find_value(nodes, fn
      %Node{component: ^component} = node ->
        node

      %Node{children: children} ->
        find_component(children, component)

      _node ->
        nil
    end)
  end
end
