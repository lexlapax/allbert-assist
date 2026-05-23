defmodule StockSageWeb.WorkspaceLive do
  @moduledoc """
  StockSage-owned LiveView shell for the app workspace surface.
  """

  use AllbertAssistWeb, :live_view

  alias StockSage.{Analyses, Queue}
  alias StockSageWeb.Components.AppShell
  alias StockSageWeb.Live

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Live.assign_context(:stocksage_workspace)
     |> load_dashboard()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main
      id="stocksage-workspace"
      class="min-h-screen overflow-x-hidden bg-zinc-950 px-4 py-6 text-zinc-100 sm:px-6"
      data-active-app={@active_app}
      data-session-id={@session_id}
      data-surface={@stocksage_surface}
    >
      <a
        href="#stocksage-main-content"
        class="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded focus:bg-emerald-300 focus:px-3 focus:py-2 focus:text-zinc-950"
      >
        Skip to StockSage content
      </a>
      <AppShell.disabled_state :if={!@web_enabled?} />
      <section :if={@web_enabled?} class="mx-auto flex max-w-6xl flex-col gap-5">
        <header
          id="stocksage-main-content"
          class="flex flex-col gap-3 border-b border-zinc-800 pb-4 md:flex-row md:items-end md:justify-between"
          tabindex="-1"
        >
          <div class="min-w-0">
            <p class="text-sm font-semibold uppercase text-emerald-300">StockSage</p>
            <h1 class="break-words text-3xl font-semibold tracking-normal">
              Financial analysis workspace
            </h1>
          </div>
          <AppShell.nav current={:workspace} />
        </header>

        <AppShell.state_panel
          :if={@load_error}
          id="stocksage-workspace-error"
          title="Workspace unavailable"
          body={@load_error}
          tone={:error}
          role="alert"
        />

        <section
          :if={!@load_error}
          id="stocksage-workspace-summary"
          class="grid gap-3 sm:grid-cols-3"
          aria-label="StockSage workspace summary"
        >
          <.summary_tile
            label="Analyses"
            value={length(@recent_analyses)}
            href={~p"/stocksage/analyses"}
          />
          <.summary_tile label="Queue" value={length(@queue_entries)} href={~p"/stocksage/queue"} />
          <.summary_tile label="Outcomes" value={@trends.returned} href={~p"/stocksage/trends"} />
        </section>

        <section
          :if={
            !@load_error && @recent_analyses == [] && @queue_entries == [] && @trends.returned == 0
          }
          id="stocksage-workspace-empty"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <h2 class="text-lg font-semibold">No StockSage activity yet</h2>
          <p class="mt-2 max-w-2xl text-sm text-zinc-300">
            Analyses, queued work, and observed outcomes will appear after StockSage records them.
          </p>
        </section>

        <section
          :if={!@load_error && @recent_analyses != []}
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <h2 class="text-lg font-semibold">Recent analyses</h2>
          <ul id="stocksage-workspace-recent-analyses" class="mt-4 divide-y divide-zinc-800">
            <li
              :for={analysis <- @recent_analyses}
              id={"stocksage-workspace-analysis-#{analysis.id}"}
              class="py-3"
            >
              <.link
                navigate={~p"/stocksage/analyses/#{analysis.id}"}
                class="font-medium text-emerald-200 hover:text-emerald-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300"
              >
                {analysis.symbol || analysis.id}
              </.link>
              <p class="mt-1 break-words text-sm text-zinc-400">
                {analysis.status} · {analysis.engine} · {analysis.summary || "No summary recorded"}
              </p>
            </li>
          </ul>
        </section>
      </section>
    </main>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:href, :string, required: true)

  defp summary_tile(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="rounded border border-zinc-800 bg-zinc-900 p-4 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300 hover:border-emerald-400"
    >
      <span class="block text-sm text-zinc-400">{@label}</span>
      <span class="mt-1 block text-2xl font-semibold text-zinc-100">{@value}</span>
    </.link>
    """
  end

  defp load_dashboard(socket) do
    recent_analyses = Analyses.list_analyses(socket.assigns.user_id, limit: 5)
    queue_entries = Queue.list_entries(socket.assigns.user_id, limit: 5)
    trends = Analyses.summarize_trends(socket.assigns.user_id, limit: 5)

    assign(socket,
      recent_analyses: recent_analyses,
      queue_entries: queue_entries,
      trends: trends,
      load_error: nil
    )
  rescue
    exception ->
      assign(socket,
        recent_analyses: [],
        queue_entries: [],
        trends: %{returned: 0, counts: %{}, outcomes: []},
        load_error: Exception.message(exception)
      )
  end
end
