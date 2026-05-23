defmodule StockSageWeb.Components.AppShell do
  @moduledoc """
  Shared StockSage LiveView chrome for app-owned surfaces.
  """

  use AllbertAssistWeb, :html

  attr(:current, :atom, required: true)

  def nav(assigns) do
    assigns =
      assign(assigns, :items, [
        %{id: :workspace, label: "Home", path: ~p"/stocksage", icon: "hero-squares-2x2-micro"},
        %{
          id: :analyses,
          label: "Analyses",
          path: ~p"/stocksage/analyses",
          icon: "hero-chart-bar-micro"
        },
        %{id: :queue, label: "Queue", path: ~p"/stocksage/queue", icon: "hero-list-bullet-micro"},
        %{
          id: :trends,
          label: "Trends",
          path: ~p"/stocksage/trends",
          icon: "hero-arrow-trending-up-micro"
        }
      ])

    ~H"""
    <nav id="stocksage-nav" aria-label="StockSage sections" class="flex flex-wrap gap-2 text-sm">
      <.link
        :for={item <- @items}
        id={"stocksage-nav-#{item.id}"}
        navigate={item.path}
        aria-current={if item.id == @current, do: "page", else: nil}
        class={[
          "inline-flex min-h-10 items-center gap-2 rounded border px-3 py-2",
          "focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300",
          nav_class(item.id, @current)
        ]}
      >
        <.icon name={item.icon} class="size-4 shrink-0" />
        <span>{item.label}</span>
      </.link>
    </nav>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:body, :string, default: nil)
  attr(:tone, :atom, default: :neutral)
  attr(:rest, :global)

  def state_panel(assigns) do
    ~H"""
    <section id={@id} class={["rounded border p-5", panel_class(@tone)]} {@rest}>
      <h2 class="text-lg font-semibold">{@title}</h2>
      <p :if={present?(@body)} class="mt-2 max-w-3xl text-sm text-zinc-300">{@body}</p>
    </section>
    """
  end

  attr(:id, :string, default: "stocksage-disabled")

  def disabled_state(assigns) do
    ~H"""
    <.state_panel
      id={@id}
      title="StockSage web surfaces are disabled"
      body="Enable stocksage.web.enabled in Settings Central to use this app surface."
      tone={:muted}
      role="status"
    />
    """
  end

  defp nav_class(id, id), do: "border-emerald-400 bg-emerald-500/15 text-emerald-100"
  defp nav_class(_id, _current), do: "border-zinc-700 text-zinc-200 hover:border-emerald-400"

  defp panel_class(:error), do: "border-red-500/40 bg-red-500/10"
  defp panel_class(:success), do: "border-emerald-500/40 bg-emerald-500/10"
  defp panel_class(:warning), do: "border-amber-500/40 bg-amber-500/10"
  defp panel_class(:muted), do: "border-zinc-800 bg-zinc-900"
  defp panel_class(_tone), do: "border-zinc-800 bg-zinc-900"

  defp present?(value) when value in [nil, ""], do: false
  defp present?(_value), do: true
end
