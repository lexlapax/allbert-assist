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
  # the app (release-pinned, not semantic-per-app). v0.24 adds the
  # objective runtime, canonical turn signals, and objective surfaces.
  # Convention is documented in DEVELOPMENT.md "App version metadata".
  def version, do: "0.25.0"

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
        label: "Allbert Chat",
        path: "/agent",
        kind: :chat,
        status: :available,
        nodes: [
          %Node{
            id: "chat-root",
            component: :chat,
            children: [
              %Node{id: "chat-timeline", component: :timeline},
              %Node{id: "chat-composer", component: :composer}
            ]
          }
        ],
        fallback_text: "Allbert chat is available at /agent."
      }
    ]
  end

  def surface_catalog do
    [
      %{component: :chat, allowed_props: [], allowed_bindings: []},
      %{component: :timeline, allowed_props: [], allowed_bindings: []},
      %{component: :composer, allowed_props: [], allowed_bindings: []}
    ]
  end

  def fallback_surface(:agent), do: {:ok, "Allbert chat is available at /agent."}

  def fallback_surface(_surface_id), do: {:error, :not_found}
end
