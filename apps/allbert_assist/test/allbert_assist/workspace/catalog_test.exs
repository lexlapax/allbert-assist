defmodule AllbertAssist.Workspace.CatalogTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Catalog
  alias AllbertAssist.Workspace.Fragment.Body, as: FragmentBody
  alias AllbertAssist.Workspace.Fragment.Envelope

  test "known components returns the 42-component v0.26 allow-list" do
    components = Catalog.known_components()

    assert length(components) == 42
    assert Enum.uniq(components) == components

    assert Enum.all?(
             [
               :route,
               :chat,
               :timeline,
               :composer,
               :status_badge,
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

  test "workspace tree returns the v0.26 core /agent surface" do
    surface = Catalog.workspace_tree(user_id: "local", thread_id: "thread-1")

    assert surface.id == :agent
    assert surface.path == "/agent"
    assert surface.kind == :workspace
    assert surface.metadata.workspace == %{user_id: "local", thread_id: "thread-1"}

    assert [%Node{component: :workspace, children: children}] = surface.nodes
    assert Enum.any?(children, &match?(%Node{component: :chat}, &1))
    assert Enum.any?(children, &match?(%Node{component: :canvas}, &1))
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

    assert [%Node{component: :workspace, children: children}] = surface.nodes

    assert %Node{children: [%Node{component: :tile, children: [canvas_child]}]} =
             Enum.find(children, &(&1.component == :canvas))

    assert canvas_child.component == :text
    assert canvas_child.props.body == "Canvas text"

    assert %Node{children: [%Node{component: :ephemeral_surface, children: [ephemeral_child]}]} =
             Enum.find(children, &(&1.component == :ephemeral_surface))

    assert ephemeral_child.component == :approval_card
    assert ephemeral_child.props.body == "Approval text"
  end

  test "renderer dispatch is web-agnostic component metadata" do
    assert {:ok, :workspace} = Catalog.component_renderer(:workspace)
    assert {:error, :unknown_component} = Catalog.component_renderer(:invented)
  end

  defp fragment_body(component, body) do
    FragmentBody.encode(%Envelope{
      id: "frag-catalog",
      surface: %Surface{
        id: :fragment,
        app_id: :allbert,
        label: "Fragment",
        path: "/agent",
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
end
