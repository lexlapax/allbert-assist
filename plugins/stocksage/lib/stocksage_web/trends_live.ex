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
            <h1 class="break-words text-3xl font-semibold tracking-normal">Trends</h1>
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
          class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
          aria-label="StockSage trend metrics"
        >
          <article class="rounded border border-zinc-800 bg-zinc-900 p-4">
            <h2 class="text-sm uppercase text-zinc-500">Resolved</h2>
            <p class="mt-1 text-2xl font-semibold">{@trends.accuracy.resolved}</p>
            <p class="mt-1 text-xs text-zinc-500">of {@trends.returned} observed</p>
          </article>
          <article class="rounded border border-zinc-800 bg-zinc-900 p-4">
            <h2 class="text-sm uppercase text-zinc-500">Win rate</h2>
            <p class="mt-1 text-2xl font-semibold">{format_percent(@trends.accuracy.win_rate)}</p>
            <p class="mt-1 text-xs text-zinc-500">resolved outcomes</p>
          </article>
          <article class="rounded border border-zinc-800 bg-zinc-900 p-4">
            <h2 class="text-sm uppercase text-zinc-500">Avg return</h2>
            <p class="mt-1 text-2xl font-semibold">
              {format_return(@trends.accuracy.avg_return_pct)}
            </p>
            <p class="mt-1 text-xs text-zinc-500">realized, no benchmark</p>
          </article>
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
          :if={!@load_error && @trends.rating_calibration != []}
          id="stocksage-rating-calibration"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <h2 class="text-lg font-semibold">Rating calibration</h2>
          <div class="mt-4 overflow-x-auto">
            <table class="min-w-full text-left text-sm">
              <thead class="text-xs uppercase text-zinc-500">
                <tr>
                  <th class="py-2 pr-4 font-medium">Rating</th>
                  <th class="py-2 pr-4 font-medium">Resolved</th>
                  <th class="py-2 pr-4 font-medium">Win rate</th>
                  <th class="py-2 pr-4 font-medium">Avg return</th>
                  <th class="py-2 pr-4 font-medium">W/L/N</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-800">
                <tr
                  :for={row <- @trends.rating_calibration}
                  id={"stocksage-rating-#{safe_id(row.rating)}"}
                >
                  <td class="max-w-48 break-words py-3 pr-4 font-medium text-zinc-100">
                    {row.rating}
                  </td>
                  <td class="py-3 pr-4 text-zinc-300">{row.resolved}</td>
                  <td class="py-3 pr-4 text-zinc-300">{format_percent(row.win_rate)}</td>
                  <td class="py-3 pr-4 text-zinc-300">{format_return(row.avg_return_pct)}</td>
                  <td class="py-3 pr-4 text-zinc-400">
                    {row.wins}/{row.losses}/{row.neutral}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section
          :if={!@load_error && @trends.leaderboard != []}
          id="stocksage-leaderboard"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <h2 class="text-lg font-semibold">Symbol leaderboard</h2>
          <div class="mt-4 overflow-x-auto">
            <table class="min-w-full text-left text-sm">
              <thead class="text-xs uppercase text-zinc-500">
                <tr>
                  <th class="py-2 pr-4 font-medium">Symbol</th>
                  <th class="py-2 pr-4 font-medium">Resolved</th>
                  <th class="py-2 pr-4 font-medium">Win rate</th>
                  <th class="py-2 pr-4 font-medium">Avg return</th>
                  <th class="py-2 pr-4 font-medium">Best</th>
                  <th class="py-2 pr-4 font-medium">Worst</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-800">
                <tr :for={row <- @trends.leaderboard} id={"stocksage-leader-#{safe_id(row.symbol)}"}>
                  <td class="py-3 pr-4 font-medium text-zinc-100">{row.symbol}</td>
                  <td class="py-3 pr-4 text-zinc-300">{row.resolved}</td>
                  <td class="py-3 pr-4 text-zinc-300">{format_percent(row.win_rate)}</td>
                  <td class="py-3 pr-4 text-zinc-300">{format_return(row.avg_return_pct)}</td>
                  <td class="py-3 pr-4 text-zinc-300">{format_return(row.best_return_pct)}</td>
                  <td class="py-3 pr-4 text-zinc-300">{format_return(row.worst_return_pct)}</td>
                </tr>
              </tbody>
            </table>
          </div>
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
        trends: empty_trends(),
        load_error: Exception.message(exception)
      )
  end

  defp empty_trends do
    %{
      returned: 0,
      counts: %{},
      accuracy: %{resolved: 0, win_rate: 0.0, avg_return_pct: nil},
      rating_calibration: [],
      leaderboard: [],
      outcomes: []
    }
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

  defp format_percent(value) when is_float(value),
    do: "#{:erlang.float_to_binary(value, decimals: 2)}%"

  defp format_percent(value) when is_integer(value), do: "#{value}.00%"
  defp format_percent(_value), do: "0.00%"

  defp format_return(%Decimal{} = value), do: "#{Decimal.to_string(value, :normal)}%"
  defp format_return(nil), do: "pending"
  defp format_return(value), do: "#{value}%"

  defp safe_id(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
    |> String.slice(0, 48)
  end
end
