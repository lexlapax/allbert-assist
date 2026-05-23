defmodule StockSageWeb.QueueLive do
  @moduledoc """
  StockSage-owned LiveView shell for queued analysis runs.
  """

  use AllbertAssistWeb, :live_view

  alias StockSage.Queue
  alias StockSageWeb.Components.AppShell
  alias StockSageWeb.Live

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Live.assign_context(:stocksage_queue)
     |> load_queue()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main
      id="stocksage-queue"
      class="min-h-screen overflow-x-hidden bg-zinc-950 px-4 py-6 text-zinc-100 sm:px-6"
      data-active-app={@active_app}
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
            <h1 class="break-words text-3xl font-semibold tracking-normal">Analysis queue</h1>
          </div>
          <AppShell.nav current={:queue} />
        </header>

        <AppShell.state_panel
          :if={@load_error}
          id="stocksage-queue-error"
          title="Queue unavailable"
          body={@load_error}
          tone={:error}
          role="alert"
        />

        <AppShell.state_panel
          :if={!@load_error && @queue_entries == []}
          id="stocksage-queue-empty"
          title="No queued analyses"
          body="Queued StockSage runs will appear here after they are requested."
          tone={:muted}
        />

        <section
          :if={!@load_error && @queue_entries != []}
          id="stocksage-queue-list"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <h2 class="text-lg font-semibold">Queued analyses</h2>
          <div class="mt-4 overflow-x-auto">
            <table class="min-w-full text-left text-sm">
              <thead class="text-xs uppercase text-zinc-500">
                <tr>
                  <th class="py-2 pr-4 font-medium">Symbol</th>
                  <th class="py-2 pr-4 font-medium">Status</th>
                  <th class="py-2 pr-4 font-medium">Priority</th>
                  <th class="py-2 pr-4 font-medium">Requested</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-800">
                <tr :for={entry <- @queue_entries} id={"stocksage-queue-entry-#{entry.id}"}>
                  <td class="max-w-48 break-words py-3 pr-4 font-medium text-zinc-100">
                    {entry.symbol}
                  </td>
                  <td class="py-3 pr-4 text-zinc-300">{entry.status}</td>
                  <td class="py-3 pr-4 text-zinc-300">{entry.priority}</td>
                  <td class="py-3 pr-4 text-zinc-400">{date_value(entry.requested_for)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </section>
    </main>
    """
  end

  defp load_queue(socket) do
    assign(socket,
      queue_entries: Queue.list_entries(socket.assigns.user_id, limit: 50),
      load_error: nil
    )
  rescue
    exception ->
      assign(socket, queue_entries: [], load_error: Exception.message(exception))
  end

  defp date_value(%Date{} = date), do: Date.to_iso8601(date)
  defp date_value(nil), do: "not scheduled"
  defp date_value(value), do: to_string(value)
end
