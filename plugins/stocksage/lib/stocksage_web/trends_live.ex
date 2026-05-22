defmodule StockSageWeb.TrendsLive do
  @moduledoc """
  StockSage-owned LiveView shell for read-only trend summaries.
  """

  use AllbertAssistWeb, :live_view

  alias StockSageWeb.Live

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Live.assign_context(socket, :stocksage_trends)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main
      id="stocksage-trends"
      class="min-h-screen bg-zinc-950 px-6 py-6 text-zinc-100"
      data-active-app={@active_app}
      data-surface={@stocksage_surface}
    >
      <.disabled_state :if={!@web_enabled?} />
      <section :if={@web_enabled?} class="mx-auto flex max-w-6xl flex-col gap-5">
        <header class="border-b border-zinc-800 pb-4">
          <p class="text-sm font-semibold uppercase text-emerald-300">StockSage</p>
          <h1 class="text-3xl font-semibold tracking-normal">Trends</h1>
        </header>
        <section id="stocksage-trends-empty" class="rounded border border-zinc-800 bg-zinc-900 p-5">
          <h2 class="text-lg font-semibold">No trends loaded</h2>
          <p class="mt-2 max-w-2xl text-sm text-zinc-300">
            Trend summaries will render with existing table and section primitives in v0.27.
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
