defmodule StockSageWeb.AnalysisLive do
  @moduledoc """
  StockSage-owned LiveView shell for analysis index and detail surfaces.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Surface.Node
  alias StockSageWeb.Components.SurfaceRenderer
  alias StockSageWeb.Live

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Live.assign_context(:stocksage_analyses)
     |> assign(:analysis_id, nil)
     |> assign(:surface_nodes, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    analysis_id = Map.get(params, "id")

    {:noreply,
     socket
     |> assign(:analysis_id, analysis_id)
     |> assign(:surface_nodes, detail_surface_nodes(analysis_id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main
      id="stocksage-analyses"
      class="min-h-screen bg-zinc-950 px-6 py-6 text-zinc-100"
      data-active-app={@active_app}
      data-analysis-id={@analysis_id}
      data-surface={@stocksage_surface}
    >
      <.disabled_state :if={!@web_enabled?} />
      <section :if={@web_enabled?} class="mx-auto flex max-w-6xl flex-col gap-5">
        <header class="border-b border-zinc-800 pb-4">
          <p class="text-sm font-semibold uppercase text-emerald-300">StockSage</p>
          <h1 class="text-3xl font-semibold tracking-normal">
            {if @analysis_id, do: "Analysis #{@analysis_id}", else: "Analyses"}
          </h1>
        </header>
        <section id="stocksage-analysis-empty" class="rounded border border-zinc-800 bg-zinc-900 p-5">
          <h2 class="text-lg font-semibold">Analysis renderer pending content</h2>
          <p class="mt-2 max-w-2xl text-sm text-zinc-300">
            v0.27 M1 mounts the real route. Later v0.27 milestones fill this surface with StockSage card renderers and validated Surface nodes.
          </p>
        </section>
        <section
          :if={@surface_nodes != []}
          id="stocksage-analysis-surface-nodes"
          class="grid gap-4"
          aria-label="StockSage analysis cards"
        >
          <SurfaceRenderer.node :for={node <- @surface_nodes} node={node} />
        </section>
      </section>
    </main>
    """
  end

  defp disabled_state(assigns) do
    ~H"""
    <section
      id="stocksage-disabled"
      class="mx-auto max-w-3xl rounded border border-zinc-800 bg-zinc-900 p-5"
      role="status"
    >
      <h1 class="text-xl font-semibold">StockSage web surfaces are disabled</h1>
      <p class="mt-2 text-sm text-zinc-300">
        Enable stocksage.web.enabled in Settings Central to use this app surface.
      </p>
    </section>
    """
  end

  defp detail_surface_nodes(nil), do: []

  defp detail_surface_nodes(analysis_id) do
    [
      %Node{
        id: "analysis-card-#{safe_dom_id(analysis_id)}",
        component: :analysis_card,
        props: %{
          analysis_id: analysis_id,
          title: "Analysis #{analysis_id}",
          status: "loading",
          summary: "Loading persisted StockSage analysis detail.",
          engine: "native"
        }
      }
    ]
  end

  defp safe_dom_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> String.slice(0, 64)
  end
end
