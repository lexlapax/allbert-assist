defmodule AllbertAssist.App.CoreApp do
  @moduledoc false

  use AllbertAssist.App
  use AllbertAssist.App.SurfaceProvider

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node

  @impl true
  def app_id, do: :allbert

  @impl true
  def display_name, do: "Allbert"

  @impl true
  # App version follows the Allbert release that last meaningfully changed
  # the app (release-pinned, not semantic-per-app). v0.27 proves plugin-owned
  # app surfaces through StockSage while preserving `/agent` authority.
  # Convention is documented in DEVELOPMENT.md "App version metadata".
  def version, do: "0.28.0"

  @impl true
  def validate(_opts), do: :ok

  @impl AllbertAssist.App
  def signals do
    %{
      emits: [
        "allbert.runtime.turn.started",
        "allbert.runtime.turn.completed"
      ],
      subscribes: []
    }
  end

  @impl AllbertAssist.App
  def surfaces do
    [
      %Surface{
        id: :agent,
        app_id: :allbert,
        label: "Allbert Workspace",
        path: "/agent",
        kind: :workspace,
        status: :available,
        nodes: workspace_nodes(),
        fallback_text: "Allbert workspace is available at /agent."
      }
    ]
  end

  def surface_catalog do
    Enum.map(Surface.known_components(), fn component ->
      %{component: component, allowed_props: [], allowed_bindings: []}
    end)
  end

  def fallback_surface(:agent), do: {:ok, "Allbert workspace is available at /agent."}

  def fallback_surface(_surface_id), do: {:error, :not_found}

  defp workspace_nodes do
    [
      %Node{
        id: "workspace-root",
        component: :workspace,
        props: %{layout: "agent_shell"},
        children: [
          %Node{
            id: "workspace-header",
            component: :header,
            props: %{
              title: "Allbert Workspace",
              subtitle: "Runtime chat, canvas, and ephemeral surfaces."
            }
          },
          %Node{
            id: "workspace-objectives",
            component: :badge_strip,
            props: %{source: "objectives"}
          },
          %Node{
            id: "workspace-chat",
            component: :chat,
            props: %{region: "fallback_chat"},
            children: [
              %Node{id: "workspace-chat-timeline", component: :timeline},
              %Node{id: "workspace-chat-composer", component: :composer}
            ]
          },
          %Node{
            id: "workspace-canvas-region",
            component: :canvas,
            props: %{empty?: true, region: "canvas"},
            children: [
              %Node{
                id: "workspace-empty-canvas",
                component: :empty_state,
                props: %{
                  title: "No canvas tiles yet",
                  body: "Workspace tiles will appear here as runtime fragments land."
                }
              }
            ]
          },
          %Node{
            id: "workspace-ephemeral-region",
            component: :ephemeral_surface,
            props: %{empty?: true, region: "ephemeral"}
          }
        ]
      }
    ]
  end
end
