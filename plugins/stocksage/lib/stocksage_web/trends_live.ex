defmodule StockSageWeb.TrendsLive do
  @moduledoc """
  StockSage-owned LiveView shell for read-only trend summaries.
  """

  use AllbertAssistWeb, :live_view

  alias StockSage.Analyses
  alias StockSageWeb.Components.AppShell
  alias StockSageWeb.Live

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Live.assign_context(:stocksage_trends)
     |> load_trends()}
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
            <h1 class="text-3xl font-semibold tracking-normal">Trends</h1>
          </div>
          <AppShell.nav current={:trends} />
        </header>

        <AppShell.state_panel
          :if={@load_error}
          id="stocksage-trends-error"
          title="Trends unavailable"
          body={@load_error}
          tone={:error}
          role="alert"
        />

        <AppShell.state_panel
          :if={!@load_error && @trends.returned == 0}
          id="stocksage-trends-empty"
          title="No observed outcomes"
          body="Outcome trends will appear after StockSage records observations."
          tone={:muted}
        />

        <section
          :if={!@load_error && @trends.returned > 0}
          id="stocksage-trends-summary"
          class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5"
          aria-label="StockSage outcome counts"
        >
          <article
            :for={{label, count} <- trend_counts(@trends)}
            id={"stocksage-trend-#{label}"}
            class="rounded border border-zinc-800 bg-zinc-900 p-4"
          >
            <h2 class="text-sm uppercase text-zinc-500">{label}</h2>
            <p class="mt-1 text-2xl font-semibold">{count}</p>
          </article>
        </section>

        <section
          :if={!@load_error && @trends.outcomes != []}
          id="stocksage-trend-outcomes"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <h2 class="text-lg font-semibold">Observed outcomes</h2>
          <div class="mt-4 overflow-x-auto">
            <table class="min-w-full text-left text-sm">
              <thead class="text-xs uppercase text-zinc-500">
                <tr>
                  <th class="py-2 pr-4 font-medium">Symbol</th>
                  <th class="py-2 pr-4 font-medium">Label</th>
                  <th class="py-2 pr-4 font-medium">Horizon</th>
                  <th class="py-2 pr-4 font-medium">Return</th>
                  <th class="py-2 pr-4 font-medium">Observed</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-800">
                <tr :for={outcome <- @trends.outcomes} id={"stocksage-outcome-#{outcome.id}"}>
                  <td class="max-w-48 break-words py-3 pr-4 font-medium text-zinc-100">
                    {outcome.symbol}
                  </td>
                  <td class="py-3 pr-4 text-zinc-300">{outcome.label}</td>
                  <td class="py-3 pr-4 text-zinc-300">{outcome.horizon_days || "open"}</td>
                  <td class="py-3 pr-4 text-zinc-300">{decimal_value(outcome.return_pct)}</td>
                  <td class="py-3 pr-4 text-zinc-400">{date_value(outcome.observed_on)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </section>
    </main>
    """
  end

  defp load_trends(socket) do
    trends = Analyses.summarize_trends(socket.assigns.user_id, limit: 50)
    assign(socket, trends: trends, load_error: nil)
  rescue
    exception ->
      assign(socket,
        trends: %{returned: 0, counts: %{}, outcomes: []},
        load_error: Exception.message(exception)
      )
  end

  defp trend_counts(%{counts: counts}) when is_map(counts) do
    counts
    |> Enum.sort_by(fn {label, _count} -> label end)
  end

  defp trend_counts(_trends), do: []

  defp date_value(%Date{} = date), do: Date.to_iso8601(date)
  defp date_value(nil), do: "not recorded"
  defp date_value(value), do: to_string(value)

  defp decimal_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_value(nil), do: "pending"
  defp decimal_value(value), do: to_string(value)
end
