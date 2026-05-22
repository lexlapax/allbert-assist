defmodule StockSageWeb.AnalysisLive do
  @moduledoc """
  StockSage-owned LiveView shell for analysis index and detail surfaces.
  """

  use AllbertAssistWeb, :live_view

  alias StockSageWeb.Live

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Live.assign_context(socket, :stocksage_analyses)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :analysis_id, Map.get(params, "id"))}
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
end
