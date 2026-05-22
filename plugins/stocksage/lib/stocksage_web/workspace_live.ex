defmodule StockSageWeb.WorkspaceLive do
  @moduledoc """
  StockSage-owned LiveView shell for the app workspace surface.
  """

  use AllbertAssistWeb, :live_view

  alias StockSageWeb.Live

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Live.assign_context(socket, :stocksage_workspace)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main
      id="stocksage-workspace"
      class="min-h-screen bg-zinc-950 px-6 py-6 text-zinc-100"
      data-active-app={@active_app}
      data-session-id={@session_id}
      data-surface={@stocksage_surface}
    >
      <.disabled_state :if={!@web_enabled?} />
      <section :if={@web_enabled?} class="mx-auto flex max-w-6xl flex-col gap-5">
        <header class="flex flex-col gap-3 border-b border-zinc-800 pb-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p class="text-sm font-semibold uppercase text-emerald-300">StockSage</p>
            <h1 class="text-3xl font-semibold tracking-normal">Financial analysis workspace</h1>
          </div>
          <nav aria-label="StockSage sections" class="flex flex-wrap gap-2 text-sm">
            <.link
              navigate={~p"/stocksage/analyses"}
              class="rounded border border-zinc-700 px-3 py-2 hover:border-emerald-400"
            >
              Analyses
            </.link>
            <.link
              navigate={~p"/stocksage/queue"}
              class="rounded border border-zinc-700 px-3 py-2 hover:border-emerald-400"
            >
              Queue
            </.link>
            <.link
              navigate={~p"/stocksage/trends"}
              class="rounded border border-zinc-700 px-3 py-2 hover:border-emerald-400"
            >
              Trends
            </.link>
          </nav>
        </header>
        <section id="stocksage-workspace-empty" class="rounded border border-zinc-800 bg-zinc-900 p-5">
          <h2 class="text-lg font-semibold">Ready for StockSage surfaces</h2>
          <p class="mt-2 max-w-2xl text-sm text-zinc-300">
            The v0.27 app surface is mounted. Analyses, queue entries, and trends will render here through StockSage-owned LiveViews.
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
